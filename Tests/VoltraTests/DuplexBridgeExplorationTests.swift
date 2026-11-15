import XCTest
import AudioToolbox
import AudioDSP
import CoreAudio
@testable import Voltra

final class DuplexBridgeExplorationTests: XCTestCase {
    func testTapToVirtualOutputWithInputDisabled() throws {
        guard #available(macOS 14.2, *), ProcessInfo.processInfo.environment["VOLTRA_DUPLEX_BRIDGE_TEST"] == "1" else { throw XCTSkip("Experimento duplex desativado") }
        let suite = "VoltraBridge-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AudioService(defaults: defaults, startTimer: false)
        guard let device = service.devices.first(where: { $0.input && $0.output && $0.transport == kAudioDeviceTransportTypeVirtual }) else { throw XCTSkip("Nenhuma saída virtual duplex disponível") }
        let originalInput = service.defaultInput, originalOutput = service.defaultOutput
        func check(_ status: OSStatus, _ step: String) throws {
            XCTAssertEqual(status, noErr, "\(step): \(status)")
            if status != noErr { throw NSError(domain: "VoltraBridge", code: Int(status)) }
        }
        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("voltra-bridge-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var le = value.littleEndian; withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) } }
        let environment = ProcessInfo.processInfo.environment
        let requestedSeconds = Int(environment["VOLTRA_BRIDGE_SECONDS"] ?? "") ?? (environment["VOLTRA_BRIDGE_LONG"] == "1" ? 20 : 4)
        let measuredSeconds = min(60, max(4, requestedSeconds))
        let frames = 48000 * (measuredSeconds + 5)
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 4)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(2)); append(UInt32(48000)); append(UInt32(48000 * 4)); append(UInt16(4)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 4))
        for i in 0..<frames { let value = Int16(1200 * sin(2 * Double.pi * 440 * Double(i) / 48000)); append(value); append(value) }
        try wav.write(to: wavURL)
        let source = Process(); source.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); source.arguments = [wavURL.path]
        try source.run(); defer { if source.isRunning { source.terminate(); source.waitUntilExit() } }
        var object: AudioObjectID = 0
        for _ in 0..<80 {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = source.processIdentifier, size = UInt32(MemoryLayout<AudioObjectID>.size)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
            if object != 0 { break }; Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotEqual(object, 0)
        guard object != 0 else { return }
        let simulateCleanupFailure = ProcessInfo.processInfo.environment["VOLTRA_BRIDGE_CLEANUP_FAILURE"] == "1"
        let differentRate = environment["VOLTRA_BRIDGE_DIFFERENT_RATE"] == "1"
        if differentRate {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var rate: Float64 = 0, size = UInt32(MemoryLayout<Float64>.size)
            try check(AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &rate), "output sample rate")
            guard abs(rate - 44100) > 0.01 else { throw XCTSkip("A saída virtual já opera em 44,1 kHz") }
            print("VOLTRA_BRIDGE_OUTPUT_RATE \(rate)")
        }
        let cleanup: (OSStatus) -> OSStatus = { status in simulateCleanupFailure && status == noErr ? -1 : status }
        let bridge = environment["VOLTRA_BRIDGE_PREFILL"] == "1"
            ? DuplexProcessTap(cleanupResult: cleanup, experimentalCaptureRate: differentRate ? 44100 : nil, prefillFrames: 2048)
            : DuplexProcessTap(cleanupResult: cleanup, experimentalCaptureRate: differentRate ? 44100 : nil)
        bridge.setGain(0.5, muted: false)
        try bridge.start(processes: [object], output: device)
        if differentRate { XCTAssertEqual(bridge.clientSampleRate ?? 0, 44100, accuracy: 0.01) }
        defer { bridge.stop() }
        Thread.sleep(forTimeInterval: 1.0)
        if environment["VOLTRA_PROBE_OWN_OUTPUT"] == "1" {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = ProcessInfo.processInfo.processIdentifier, processObject: AudioObjectID = 0
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject), "translate test process")
            guard processObject != 0 else { throw XCTSkip("A saída AUHAL do processo de teste não foi exposta como processo de áudio") }
            let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
            description.isPrivate = true; description.muteBehavior = .unmuted
            var tap: AudioObjectID = 0
            try check(AudioHardwareCreateProcessTap(description, &tap), "create self-only tap")
            defer { XCTAssertEqual(AudioHardwareDestroyProcessTap(tap), noErr) }
            var tapAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var tapUID: CFString?, tapSize = UInt32(MemoryLayout<CFString?>.size)
            let status = withUnsafeMutablePointer(to: &tapUID) { AudioObjectGetPropertyData(tap, &tapAddress, 0, nil, &tapSize, UnsafeMutableRawPointer($0)) }
            try check(status, "read tap UID")
            let uid = try XCTUnwrap(tapUID)
            var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription(), formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format), "read self-only tap format")
            guard format.mFormatID == kAudioFormatLinearPCM, (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0, (format.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) == 0, format.mChannelsPerFrame == 2, format.mBytesPerFrame == 8, format.mSampleRate > 0 else { throw XCTSkip("Formato da captura de verificação não é estéreo Float32") }
            let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "Voltra Self Probe", kAudioAggregateDeviceUIDKey: "com.voltra.selfprobe." + UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid]]]
            var probe: AudioObjectID = 0
            try check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &probe), "create self-only aggregate")
            defer { XCTAssertEqual(AudioHardwareDestroyAggregateDevice(probe), noErr) }
            let ring = try XCTUnwrap(vaudio_ring_create(16384))
            var safeToFree = true
            defer { if safeToFree { vaudio_ring_destroy(ring) } }
            var io: AudioDeviceIOProcID?
            let queue = DispatchQueue(label: "com.voltra.selfprobe")
            let block: AudioDeviceIOBlock = { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                if buffers.count == 1, buffers[0].mNumberChannels == 2, let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    _ = vaudio_ring_write(ring, data, buffers[0].mDataByteSize / 8)
                }
            }
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, probe, queue, block), "create self-only callback")
            let proc = try XCTUnwrap(io)
            defer { let status = AudioDeviceDestroyIOProcID(probe, proc); if status != noErr { safeToFree = false }; XCTAssertEqual(status, noErr) }
            try check(AudioDeviceStart(probe, proc), "start self-only probe")
            safeToFree = false
            Thread.sleep(forTimeInterval: 0.5)
            try check(AudioDeviceStop(probe, proc), "stop self-only probe")
            safeToFree = true
            let available = vaudio_ring_available(ring)
            var samples = [Float](repeating: 0, count: Int(available) * 2)
            let read = samples.withUnsafeMutableBufferPointer { vaudio_ring_read(ring, $0.baseAddress, available) }
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            print("VOLTRA_SELF_OUTPUT_PROBE frames=\(read) peak=\(peak) rate=\(format.mSampleRate)")
            guard read > 1024 else { throw XCTSkip("O Process Tap não forneceu quadros do próprio processo") }
            XCTAssertGreaterThan(peak, 0.001, "O sinal reproduzido deve aparecer na captura do próprio processo")
            guard peak > 0.001 else { return }
            let start = 256, end = Int(read) - 256
            var crossings = 0, sum = 0.0
            for frame in start..<end {
                let current = samples[frame * 2], previous = samples[(frame - 1) * 2]
                if previous <= 0 && current > 0 { crossings += 1 }
                sum += Double(current * current)
            }
            let frequency = Double(crossings) * format.mSampleRate / Double(end - start)
            let rms = sqrt(sum / Double(end - start))
            print("VOLTRA_SELF_OUTPUT_SIGNAL frequency=\(frequency) rms=\(rms)")
            XCTAssertEqual(frequency, 440, accuracy: 5)
            XCTAssertEqual(rms, Double(1200.0 / 32768.0 * 0.5 / sqrt(2.0)), accuracy: 0.004)
            func capturedPeak() throws -> Float {
                try check(AudioDeviceStart(probe, proc), "restart self-only probe")
                safeToFree = false
                Thread.sleep(forTimeInterval: 0.35)
                try check(AudioDeviceStop(probe, proc), "stop self-only probe")
                safeToFree = true
                let count = vaudio_ring_available(ring)
                var captured = [Float](repeating: 0, count: Int(count) * 2)
                let framesRead = captured.withUnsafeMutableBufferPointer { vaudio_ring_read(ring, $0.baseAddress, count) }
                XCTAssertGreaterThan(framesRead, 1024)
                return captured.reduce(Float(0)) { max($0, abs($1)) }
            }
            bridge.setGain(0.5, muted: true)
            Thread.sleep(forTimeInterval: 0.25)
            let mutedPeak = try capturedPeak()
            XCTAssertEqual(mutedPeak, 0, accuracy: 0.00001)
            bridge.setGain(0.5, muted: false)
            Thread.sleep(forTimeInterval: 0.25)
            let restoredPeak = try capturedPeak()
            XCTAssertEqual(restoredPeak, peak, accuracy: 0.003)
            print("VOLTRA_SELF_OUTPUT_MUTE muted=\(mutedPeak) restored=\(restoredPeak)")
        }
        let baselineUnder = bridge.underruns, baselineOver = bridge.overruns
        XCTAssertFalse(bridge.shouldStopForBufferHealth(at: ProcessInfo.processInfo.systemUptime))
        print("VOLTRA_BRIDGE_STARTUP missing=\(baselineUnder) dropped=\(baselineOver)")
        if environment["VOLTRA_REQUIRE_PREFILL"] == "1" {
            XCTAssertEqual(baselineUnder, 0, "A pré-carga deve evitar perdas durante a partida")
            XCTAssertEqual(baselineOver, 0)
        }
        var minBuffered = UInt32.max, maxBuffered: UInt32 = 0
        let deadline = Date().addingTimeInterval(Double(measuredSeconds))
        while Date() < deadline {
            let buffered = bridge.bufferedFrames
            minBuffered = min(minBuffered, buffered); maxBuffered = max(maxBuffered, buffered)
            Thread.sleep(forTimeInterval: 0.02)
        }
        print("VOLTRA_BRIDGE_BUFFER min=\(minBuffered) max=\(maxBuffered)")
        let (callbacks, peak, output) = bridge.diagnostics
        let missing = bridge.underruns - baselineUnder, dropped = bridge.overruns - baselineOver
        print("VOLTRA_BRIDGE callbacks=\(callbacks) input=\(peak) output=\(output) missing=\(missing) dropped=\(dropped)")
        XCTAssertGreaterThan(callbacks, 0)
        XCTAssertGreaterThan(peak, 0.001)
        XCTAssertEqual(output / peak, 0.5, accuracy: 0.02)
        XCTAssertEqual(missing, 0)
        XCTAssertEqual(dropped, 0)
        XCTAssertFalse(bridge.shouldStopForBufferHealth(at: ProcessInfo.processInfo.systemUptime))
        bridge.setGain(0.5, muted: true)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertGreaterThan(bridge.diagnostics.1, 0.001)
        XCTAssertEqual(bridge.diagnostics.2, 0, accuracy: 0.00001)
        bridge.setGain(0.5, muted: false)
        source.terminate(); source.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(bridge.diagnostics.2, 0, accuracy: 0.00001)
        XCTAssertEqual(try bridge.inputEnabled(), false)
        bridge.stop()
        XCTAssertFalse(bridge.running)
        XCTAssertEqual(bridge.cleanupFailed, simulateCleanupFailure)
        XCTAssertEqual(bridge.hasRetainedCallbackContext, simulateCleanupFailure)
        bridge.stop()
        XCTAssertEqual(bridge.cleanupFailed, simulateCleanupFailure, "Uma falha de limpeza não deve ser esquecida")
        XCTAssertEqual(bridge.hasRetainedCallbackContext, simulateCleanupFailure)
        service.refresh(); XCTAssertEqual(service.defaultInput, originalInput); XCTAssertEqual(service.defaultOutput, originalOutput)
    }
}
