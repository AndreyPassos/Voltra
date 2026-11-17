import Foundation
import CoreAudio
import AudioToolbox
import AudioDSP

enum OutputStreamListPolicy {
    enum Result { case unavailable, supported, multiple, invalid }
    static func classify(bytes: UInt32) -> Result {
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard bytes > 0 else { return .unavailable }
        guard bytes % size == 0 else { return .invalid }
        return bytes == size ? .supported : .multiple
    }
}

enum StandardFormatPolicy {
    static func isConvertibleRateMismatch(input: AudioStreamBasicDescription, output: AudioStreamBasicDescription) -> Bool {
        guard input.mSampleRate.isFinite, output.mSampleRate.isFinite, input.mSampleRate > 0, output.mSampleRate > 0,
              abs(input.mSampleRate - output.mSampleRate) >= 0.01 else { return false }
        var matched = output
        matched.mSampleRate = input.mSampleRate
        return supports(input: input, output: matched) && output.mChannelsPerFrame == 2
    }
    static func supports(input: AudioStreamBasicDescription, output: AudioStreamBasicDescription) -> Bool {
        func compatible(_ format: AudioStreamBasicDescription, channels: UInt32) -> Bool {
            format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
            (format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)) == (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) &&
            (format.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) == 0 &&
            format.mChannelsPerFrame == channels && format.mBytesPerFrame == channels * 4 &&
            format.mFramesPerPacket == 1 && format.mBytesPerPacket == channels * 4 &&
            format.mSampleRate.isFinite && format.mSampleRate > 0
        }
        return compatible(input, channels: 2) && (compatible(output, channels: 2) || compatible(output, channels: 1)) && abs(input.mSampleRate - output.mSampleRate) < 0.01
    }
}

@available(macOS 14.2, *)
final class ProcessTap {
    enum Failure: LocalizedError {
        case coreAudio(String, OSStatus)
        case unsupported(String)
        case rateMismatch
        var errorDescription: String? {
            switch self {
            case let .coreAudio(step, status): return "\(VoltraLanguage.text(step)): Core Audio \(status)"
            case let .unsupported(reason): return reason
            case .rateMismatch: return VoltraLanguage.text("Formato ou taxa de áudio não suportados para esta saída.")
            }
        }
    }
    private let cleanupResult: (OSStatus) -> OSStatus
    init(cleanupResult: @escaping (OSStatus) -> OSStatus = { $0 }) { self.cleanupResult = cleanupResult }
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private let dsp = vdsp_create()!
    private let queue = DispatchQueue(label: "voltra.audio.render", qos: .userInteractive)
    private(set) var running = false
    private(set) var cleanupFailed = false
    deinit { stop(); if !cleanupFailed { vdsp_destroy(dsp) } }
    var bufferFrames: (UInt32, UInt32) { (vdsp_input_frames(dsp), vdsp_output_frames(dsp)) }
    var underruns: UInt32 { vdsp_underruns(dsp) }
    var overruns: UInt32 { vdsp_overruns(dsp) }
    var diagnostics: (UInt32, Float, Float) { (vdsp_callbacks(dsp), vdsp_input_peak(dsp), vdsp_output_peak(dsp)) }
    func setGain(_ value: Float, muted: Bool) { vdsp_set_gain(dsp, value, muted) }
    private func checked(_ step: String, _ status: OSStatus) throws { if status != noErr { throw Failure.coreAudio(step, status) } }
    private func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) throws {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, UnsafeMutableRawPointer($0)) }
        try checked("Ler propriedade de áudio", status)
    }
    private func inputStreams(_ id: AudioObjectID) throws -> [AudioObjectID] {
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try checked("Consultar fluxos de entrada", AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size))
        guard size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { throw Failure.unsupported(VoltraLanguage.text("Lista de fluxos de entrada inválida.")) }
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!) }
        try checked("Ler fluxos de entrada", status)
        return ids
    }
    func start(processes: [AudioObjectID], output: AudioDevice) throws {
        guard !cleanupFailed, !processes.isEmpty, output.output else { throw Failure.unsupported(VoltraLanguage.text("Processo ou saída indisponível.")) }
        guard !output.input else { throw Failure.unsupported(VoltraLanguage.text("Esta saída também possui entrada física; o isolamento do microfone não pôde ser garantido neste dispositivo.")) }
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.name = "Voltra Process Tap"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try checked("Criar captura", AudioHardwareCreateProcessTap(description, &tap))
            var tapUID: CFString?
            try read(tap, kAudioTapPropertyUID, into: &tapUID)
            guard let uid = tapUID else { throw Failure.unsupported(VoltraLanguage.text("O sistema não forneceu o identificador da captura.")) }
            var tapFormat = AudioStreamBasicDescription()
            try read(tap, kAudioTapPropertyFormat, into: &tapFormat)
            let spec: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Voltra Audio",
                kAudioAggregateDeviceUIDKey: "com.voltra.aggregate." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: true]]
            ]
            try checked("Criar dispositivo de áudio", AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate))
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            try checked("Consultar saída", AudioObjectGetPropertyDataSize(aggregate, &a, 0, nil, &bytes))
            switch OutputStreamListPolicy.classify(bytes: bytes) {
            case .unavailable: throw Failure.unsupported(VoltraLanguage.text("Esta saída não possui fluxos disponíveis."))
            case .multiple: throw Failure.unsupported(VoltraLanguage.text("Esta saída possui múltiplos fluxos e ainda não é suportada."))
            case .invalid: throw Failure.unsupported(VoltraLanguage.text("Lista de fluxos de saída inválida."))
            case .supported: break
            }
            var stream: AudioObjectID = 0
            try checked("Consultar fluxo", AudioObjectGetPropertyData(aggregate, &a, 0, nil, &bytes, &stream))
            var format = AudioStreamBasicDescription()
            try read(stream, kAudioStreamPropertyVirtualFormat, into: &format)
            let aggregateStreams = try inputStreams(aggregate)
            guard aggregateStreams.count == 1, let inputStream = aggregateStreams.first else { throw Failure.unsupported(VoltraLanguage.text("Quantidade de fluxos de entrada não suportada.")) }
            var inputFormat = AudioStreamBasicDescription()
            try read(inputStream, kAudioStreamPropertyVirtualFormat, into: &inputFormat)
            guard StandardFormatPolicy.supports(input: inputFormat, output: format) else {
                if StandardFormatPolicy.isConvertibleRateMismatch(input: inputFormat, output: format) { throw Failure.rateMismatch }
                throw Failure.unsupported(VoltraLanguage.text("Formato ou taxa de áudio não suportados para esta saída."))
            }
            let state = dsp
            let block: AudioDeviceIOBlock = { _, input, _, output, _ in
                let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let outs = UnsafeMutableAudioBufferListPointer(output)
                for (index, buffer) in outs.enumerated() {
                    guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    if index == 0, ins.count == 1, outs.count == 1, ins[0].mNumberChannels == 2, buffer.mNumberChannels == format.mChannelsPerFrame, let source = ins[0].mData?.assumingMemoryBound(to: Float.self) {
                        if format.mChannelsPerFrame == 1 {
                            vdsp_stereo_to_mono(state, source, ins[0].mDataByteSize / 8, out, buffer.mDataByteSize / 4)
                        } else {
                            vdsp_process(state, source, ins[0].mDataByteSize / 4, out, buffer.mDataByteSize / 4)
                        }
                    } else { vdsp_format_mismatch(state); memset(out, 0, Int(buffer.mDataByteSize)) }
                }
            }
            try checked("Preparar reprodução", AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, block))
            guard let proc else { throw Failure.unsupported(VoltraLanguage.text("Não foi possível preparar a reprodução.")) }
            try checked("Iniciar reprodução", AudioDeviceStart(aggregate, proc))
            running = true
        } catch { stop(); throw error }
    }
    func stop() {
        func note(_ status: OSStatus) { if cleanupResult(status) != noErr { cleanupFailed = true } }
        if let proc {
            if running { note(AudioDeviceStop(aggregate, proc)) }
            note(AudioDeviceDestroyIOProcID(aggregate, proc)); self.proc = nil
        }
        if aggregate != 0 { note(AudioHardwareDestroyAggregateDevice(aggregate)); aggregate = 0 }
        if tap != 0 { note(AudioHardwareDestroyProcessTap(tap)); tap = 0 }
        running = false
    }
}
