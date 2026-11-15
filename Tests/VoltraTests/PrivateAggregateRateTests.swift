import XCTest
import CoreAudio
import AudioToolbox

final class PrivateAggregateRateTests: XCTestCase {
    func testPrivateTapAggregateCanSelect44100() throws {
        guard #available(macOS 14.2, *), ProcessInfo.processInfo.environment["VOLTRA_AGGREGATE_RATE_TEST"] == "1" else { throw XCTSkip("Experimento de taxa desativado") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voltra-silent-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        var wav = Data()
        func integer<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        let frames = 48000 * 8
        wav.append(contentsOf: Array("RIFF".utf8)); integer(UInt32(36 + frames * 4)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(2)); integer(UInt32(48000)); integer(UInt32(48000 * 4)); integer(UInt16(4)); integer(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); integer(UInt32(frames * 4)); wav.append(Data(repeating: 0, count: frames * 4))
        try wav.write(to: file)
        let source = Process(); source.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); source.arguments = [file.path]
        try source.run(); defer { if source.isRunning { source.terminate(); source.waitUntilExit() } }
        var object: AudioObjectID = 0
        for _ in 0..<60 {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = source.processIdentifier, size = UInt32(MemoryLayout<AudioObjectID>.size)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
            if object != 0 { break }; Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotEqual(object, 0); guard object != 0 else { return }
        let description = CATapDescription(stereoMixdownOfProcesses: [object])
        description.isPrivate = true; description.muteBehavior = .unmuted
        var tap: AudioObjectID = 0
        XCTAssertEqual(AudioHardwareCreateProcessTap(description, &tap), noErr); guard tap != 0 else { return }
        defer { XCTAssertEqual(AudioHardwareDestroyProcessTap(tap), noErr) }
        var uid: CFString?, uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(tap, &uidAddress, 0, nil, &uidSize, UnsafeMutableRawPointer($0)) }
        XCTAssertEqual(uidStatus, noErr)
        let tapUID = try XCTUnwrap(uid)
        let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "Voltra Rate Test", kAudioAggregateDeviceUIDKey: "com.voltra.ratetest.\(UUID().uuidString)", kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]]]
        var aggregate: AudioObjectID = 0
        XCTAssertEqual(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate), noErr); guard aggregate != 0 else { return }
        defer { XCTAssertEqual(AudioHardwareDestroyAggregateDevice(aggregate), noErr) }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        XCTAssertEqual(AudioObjectIsPropertySettable(aggregate, &address, &settable), noErr)
        guard settable.boolValue else { throw XCTSkip("Taxa do agregado privado não é ajustável") }
        var wanted: Float64 = 44100
        let status = AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &wanted)
        guard status == noErr else { throw XCTSkip("Agregado privado não aceitou 44,1 kHz: \(status)") }
        var actual: Float64 = 0, size = UInt32(MemoryLayout<Float64>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &actual), noErr)
        print("VOLTRA_PRIVATE_AGGREGATE_RATE requested=44100 actual=\(actual)")
        XCTAssertEqual(actual, 44100, accuracy: 0.01)
        var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var streamSize = UInt32(MemoryLayout<AudioObjectID>.size), stream: AudioObjectID = 0
        XCTAssertEqual(AudioObjectGetPropertyData(aggregate, &streamAddress, 0, nil, &streamSize, &stream), noErr)
        guard stream != 0 else { XCTFail("Agregado sem fluxo de entrada"); return }
        var proc: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "com.voltra.rate-test")
        let callback: AudioDeviceIOBlock = { _, _, _, _, _ in }
        XCTAssertEqual(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, callback), noErr)
        let io = try XCTUnwrap(proc)
        defer { XCTAssertEqual(AudioDeviceDestroyIOProcID(aggregate, io), noErr) }
        XCTAssertEqual(AudioDeviceStart(aggregate, io), noErr)
        Thread.sleep(forTimeInterval: 0.5)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription(), formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format), noErr)
        XCTAssertEqual(AudioDeviceStop(aggregate, io), noErr)
        print("VOLTRA_PRIVATE_STREAM_RATE actual=\(format.mSampleRate)")
        XCTAssertEqual(format.mSampleRate, 44100, accuracy: 0.01)
    }
}
