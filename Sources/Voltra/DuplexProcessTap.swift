import Foundation
import CoreAudio
import AudioToolbox
import AudioDSP

struct DuplexStreamHealth {
    let startedAt: TimeInterval
    private var baseline: (UInt64, UInt64)?
    init(startedAt: TimeInterval) { self.startedAt = startedAt }
    mutating func shouldStop(underruns: UInt64, overruns: UInt64, at time: TimeInterval) -> Bool {
        if time - startedAt < 1 || baseline == nil {
            baseline = (underruns, overruns)
            return false
        }
        guard let baseline else { return false }
        let missing = underruns >= baseline.0 ? underruns - baseline.0 : 0
        let dropped = overruns >= baseline.1 ? overruns - baseline.1 : 0
        return missing > 1024 || dropped > 1024
    }
}

enum DuplexFormatPolicy {
    static func supports(_ format: AudioStreamBasicDescription, outputRate: Float64) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
        (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0 &&
        (format.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) == 0 &&
        format.mChannelsPerFrame == 2 && format.mBytesPerFrame == 8 && format.mFramesPerPacket == 1 && format.mBytesPerPacket == 8 &&
        outputRate.isFinite && outputRate > 0 && format.mSampleRate.isFinite && abs(format.mSampleRate - outputRate) < 0.01
    }
    static func clientRate(tap: AudioStreamBasicDescription, capture: AudioStreamBasicDescription, outputRate: Float64) -> Float64? {
        guard outputRate.isFinite, outputRate > 0,
              supports(tap, outputRate: tap.mSampleRate),
              supports(capture, outputRate: capture.mSampleRate) else { return nil }
        return capture.mSampleRate
    }
}

private struct DuplexRenderContext { let ring: OpaquePointer; let dsp: OpaquePointer; let prefillFrames: UInt32; var started: Bool }

/// Output-only bridge for supported virtual duplex devices.
@available(macOS 14.2, *)
final class DuplexProcessTap {
    private let cleanupResult: (OSStatus) -> OSStatus
    private let experimentalCaptureRate: Float64?
    private let prefillFrames: UInt32
    private(set) var clientSampleRate: Float64?
    init(cleanupResult: @escaping (OSStatus) -> OSStatus = { $0 }, experimentalCaptureRate: Float64? = nil, prefillFrames: UInt32 = 2048) {
        self.cleanupResult = cleanupResult
        self.experimentalCaptureRate = experimentalCaptureRate
        self.prefillFrames = min(prefillFrames, 16384)
    }
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var proc: AudioDeviceIOProcID?
    private var unit: AudioComponentInstance?
    private var captureStarted = false, outputInitialized = false, outputStarted = false, attempted = false
    private let ring = vaudio_ring_create(16384)!
    private let dsp = vdsp_create()!
    private var context: UnsafeMutablePointer<DuplexRenderContext>?
    private let queue = DispatchQueue(label: "com.voltra.duplex.capture", qos: .userInteractive)
    private(set) var running = false
    private(set) var cleanupFailed = false
    var hasRetainedCallbackContext: Bool { context != nil }
    private var health: DuplexStreamHealth?
    var bufferedFrames: UInt32 { vaudio_ring_available(ring) }
    var underruns: UInt64 { vaudio_ring_underruns(ring) }
    var overruns: UInt64 { vaudio_ring_overruns(ring) }
    var diagnostics: (UInt32, Float, Float) { (vdsp_callbacks(dsp), vdsp_input_peak(dsp), vdsp_output_peak(dsp)) }
    func setGain(_ gain: Float, muted: Bool) { vdsp_set_gain(dsp, gain, muted) }
    func shouldStopForBufferHealth(at time: TimeInterval) -> Bool {
        guard var current = health else { return false }
        let failed = current.shouldStop(underruns: underruns, overruns: overruns, at: time) || vdsp_underruns(dsp) > 1024
        health = current
        return failed
    }
    private func checked(_ name: String, _ status: OSStatus) throws {
        if status != noErr { throw ProcessTap.Failure.coreAudio(name, status) }
    }
    private func read<T>(_ id: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, UnsafeMutableRawPointer($0)) }
        try checked("Ler propriedade de áudio", status)
    }
    func inputEnabled() throws -> Bool {
        guard let unit else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Processo ou saída indisponível.")) }
        var value: UInt32 = 1, size = UInt32(MemoryLayout<UInt32>.size)
        try checked("Ler propriedade de áudio", AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &value, &size))
        return value != 0
    }
    func start(processes: [AudioObjectID], output: AudioDevice) throws {
        guard !attempted, !processes.isEmpty, output.output else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Processo ou saída indisponível.")) }
        attempted = true
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.name = "Voltra Process Tap"; description.isPrivate = true; description.muteBehavior = .mutedWhenTapped
            try checked("Criar captura", AudioHardwareCreateProcessTap(description, &tap))
            var uid: CFString?
            try read(tap, selector: kAudioTapPropertyUID, value: &uid)
            guard let uid else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("O sistema não forneceu o identificador da captura.")) }
            var tapFormat = AudioStreamBasicDescription(), outputRate: Float64 = 0
            try read(tap, selector: kAudioTapPropertyFormat, value: &tapFormat)
            try read(output.id, selector: kAudioDevicePropertyNominalSampleRate, value: &outputRate)
            guard outputRate.isFinite, outputRate > 0, DuplexFormatPolicy.supports(tapFormat, outputRate: tapFormat.mSampleRate) else {
                throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Formato ou taxa de áudio não suportados para esta saída."))
            }
            let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "Voltra Audio", kAudioAggregateDeviceUIDKey: "com.voltra.aggregate.duplex." + UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid]]]
            try checked("Criar dispositivo de áudio", AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate))
            if var rate = experimentalCaptureRate {
                guard rate.isFinite && rate > 0 else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Formato ou taxa de áudio não suportados para esta saída.")) }
                var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                try checked("Preparar reprodução", AudioObjectSetPropertyData(aggregate, &rateAddress, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate))
            }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            try checked("Consultar fluxos de entrada", AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &bytes))
            guard bytes == UInt32(MemoryLayout<AudioObjectID>.size) else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Quantidade de fluxos de entrada não suportada.")) }
            var stream: AudioObjectID = 0
            try checked("Ler fluxos de entrada", AudioObjectGetPropertyData(aggregate, &address, 0, nil, &bytes, &stream))
            var streamFormat = AudioStreamBasicDescription()
            try read(stream, selector: kAudioStreamPropertyVirtualFormat, value: &streamFormat)
            guard let clientRate = DuplexFormatPolicy.clientRate(tap: tapFormat, capture: streamFormat, outputRate: outputRate) else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Formato ou taxa de áudio não suportados para esta saída.")) }
            var componentDescription = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &componentDescription) else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Não foi possível preparar a reprodução.")) }
            var instance: AudioComponentInstance?
            try checked("Preparar reprodução", AudioComponentInstanceNew(component, &instance))
            guard let instance else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Não foi possível preparar a reprodução.")) }
            unit = instance
            var disabled: UInt32 = 0, enabled: UInt32 = 1, selected = output.id
            try checked("Preparar reprodução", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, UInt32(MemoryLayout<UInt32>.size)))
            try checked("Preparar reprodução", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, UInt32(MemoryLayout<UInt32>.size)))
            try checked("Preparar reprodução", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size)))
            var format = AudioStreamBasicDescription(mSampleRate: clientRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try checked("Preparar reprodução", AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var acceptedFormat = AudioStreamBasicDescription(), acceptedSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checked("Ler propriedade de áudio", AudioUnitGetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &acceptedFormat, &acceptedSize))
            guard DuplexFormatPolicy.supports(acceptedFormat, outputRate: clientRate) else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Formato ou taxa de áudio não suportados para esta saída.")) }
            let pointer = UnsafeMutablePointer<DuplexRenderContext>.allocate(capacity: 1)
            pointer.initialize(to: DuplexRenderContext(ring: ring, dsp: dsp, prefillFrames: prefillFrames, started: prefillFrames == 0)); context = pointer
            var callback = AURenderCallbackStruct(inputProc: { raw, _, _, _, frames, data in
                let pointer = raw.assumingMemoryBound(to: DuplexRenderContext.self)
                guard let data else { return noErr }
                let buffers = UnsafeMutableAudioBufferListPointer(data)
                if !pointer.pointee.started {
                    if vaudio_ring_available(pointer.pointee.ring) < pointer.pointee.prefillFrames {
                        for buffer in buffers { if let ptr = buffer.mData { memset(ptr, 0, Int(buffer.mDataByteSize)) } }
                        return noErr
                    }
                    pointer.pointee.started = true
                }
                let state = pointer.pointee
                guard buffers.count == 1, let buffer = buffers.first, buffer.mNumberChannels == 2,
                      buffer.mDataByteSize >= frames * 8, let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    for buffer in buffers { if let ptr = buffer.mData { memset(ptr, 0, Int(buffer.mDataByteSize)) } }
                    vdsp_format_mismatch(state.dsp); return noErr
                }
                _ = vaudio_ring_read(state.ring, samples, frames)
                vdsp_process(state.dsp, samples, frames * 2, samples, frames * 2)
                return noErr
            }, inputProcRefCon: UnsafeMutableRawPointer(pointer))
            try checked("Preparar reprodução", AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try checked("Preparar reprodução", AudioUnitInitialize(instance)); outputInitialized = true
            guard try !inputEnabled() else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Não foi possível desativar a entrada desta saída.")) }
            let state = ring
            let block: AudioDeviceIOBlock = { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                if buffers.count == 1, buffers[0].mNumberChannels == 2, let samples = buffers[0].mData?.assumingMemoryBound(to: Float.self) { _ = vaudio_ring_write(state, samples, buffers[0].mDataByteSize / 8) }
            }
            try checked("Preparar reprodução", AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, block))
            guard let proc else { throw ProcessTap.Failure.unsupported(VoltraLanguage.text("Não foi possível preparar a reprodução.")) }
            try checked("Iniciar reprodução", AudioOutputUnitStart(instance)); outputStarted = true
            try checked("Iniciar reprodução", AudioDeviceStart(aggregate, proc)); captureStarted = true
            health = DuplexStreamHealth(startedAt: ProcessInfo.processInfo.systemUptime)
            clientSampleRate = clientRate
            running = true
        } catch { stop(); throw error }
    }
    func stop() {
        func note(_ status: OSStatus) { if cleanupResult(status) != noErr { cleanupFailed = true } }
        if let proc {
            if captureStarted { note(AudioDeviceStop(aggregate, proc)) }
            note(AudioDeviceDestroyIOProcID(aggregate, proc))
            self.proc = nil
        }
        captureStarted = false
        if let unit {
            if outputStarted { note(AudioOutputUnitStop(unit)) }
            if outputInitialized { note(AudioUnitUninitialize(unit)) }
            note(AudioComponentInstanceDispose(unit))
            self.unit = nil
        }
        outputStarted = false; outputInitialized = false
        if aggregate != 0 { note(AudioHardwareDestroyAggregateDevice(aggregate)); aggregate = 0 }
        if tap != 0 { note(AudioHardwareDestroyProcessTap(tap)); tap = 0 }
        // If the OS did not confirm cleanup, callbacks might still reference this memory.
        if !cleanupFailed, let context { context.deinitialize(count: 1); context.deallocate(); self.context = nil }
        health = nil
        running = false
    }
    deinit {
        stop()
        if !cleanupFailed { vaudio_ring_destroy(ring); vdsp_destroy(dsp) }
    }
}
