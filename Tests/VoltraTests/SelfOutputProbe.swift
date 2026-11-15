import XCTest
import CoreAudio
import AudioDSP

/// Captures only the current test process; never a global tap or microphone.
@available(macOS 14.2, *)
enum SelfOutputProbe {
    static func peak() throws -> (frames: UInt32, peak: Float) {
        let result = try capture()
        return (result.frames, result.samples.reduce(0) { max($0, abs($1)) })
    }
    static func capture() throws -> (frames: UInt32, samples: [Float], sampleRate: Double) {
        func check(_ status: OSStatus, _ operation: String) throws {
            guard status == noErr else { throw NSError(domain: "VoltraSelfOutputProbe.\(operation)", code: Int(status)) }
        }
        var processAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = ProcessInfo.processInfo.processIdentifier, process: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &processAddress, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "process")
        guard process != 0 else { throw XCTSkip("O processo de teste não expõe saída de áudio") }
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.isPrivate = true; description.muteBehavior = .unmuted
        var tap: AudioObjectID = 0
        try check(AudioHardwareCreateProcessTap(description, &tap), "tap")
        defer { XCTAssertEqual(AudioHardwareDestroyProcessTap(tap), noErr) }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?, uidSize = UInt32(MemoryLayout<CFString?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(tap, &uidAddress, 0, nil, &uidSize, UnsafeMutableRawPointer($0)) }
        try check(uidStatus, "uid")
        let tapUID = try XCTUnwrap(uid)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription(), formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format), "format")
        guard format.mFormatID == kAudioFormatLinearPCM, (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0, (format.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) == 0, format.mChannelsPerFrame == 2, format.mBytesPerFrame == 8 else { throw XCTSkip("Formato de captura de verificação não suportado") }
        let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "Voltra Self Probe", kAudioAggregateDeviceUIDKey: "com.voltra.selfprobe." + UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]]]
        var aggregate: AudioObjectID = 0
        try check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate), "aggregate")
        defer { XCTAssertEqual(AudioHardwareDestroyAggregateDevice(aggregate), noErr) }
        let ring = try XCTUnwrap(vaudio_ring_create(16384))
        var safeToFree = true
        defer { if safeToFree { vaudio_ring_destroy(ring) } }
        var io: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "com.voltra.self-output-probe")
        let callback: AudioDeviceIOBlock = { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if buffers.count == 1, buffers[0].mNumberChannels == 2, let samples = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                _ = vaudio_ring_write(ring, samples, buffers[0].mDataByteSize / 8)
            }
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, queue, callback), "callback")
        let proc = try XCTUnwrap(io)
        defer { let status = AudioDeviceDestroyIOProcID(aggregate, proc); if status != noErr { safeToFree = false }; XCTAssertEqual(status, noErr) }
        try check(AudioDeviceStart(aggregate, proc), "start")
        safeToFree = false
        Thread.sleep(forTimeInterval: 0.4)
        try check(AudioDeviceStop(aggregate, proc), "stop")
        safeToFree = true
        let count = vaudio_ring_available(ring)
        var samples = [Float](repeating: 0, count: Int(count) * 2)
        let frames = samples.withUnsafeMutableBufferPointer { vaudio_ring_read(ring, $0.baseAddress, count) }
        return (frames, samples, format.mSampleRate)
    }
}
