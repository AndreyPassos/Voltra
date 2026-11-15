import XCTest
import CoreAudio
@testable import Voltra

final class ConcurrentTapIntegrationTests: XCTestCase {
    func testTwoProcessesHaveIndependentGainAndMute() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Requer macOS 14.2") }
        guard ProcessInfo.processInfo.environment["VOLTRA_CONCURRENT_TAP_TEST"] == "1" else { throw XCTSkip("Teste de captura desativado") }
        let suite = "VoltraConcurrent-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AudioService(defaults: defaults, startTimer: false)
        guard let output = service.devices.first(where: { $0.id == service.defaultOutput && $0.output && !$0.input }) else { throw XCTSkip("A saída padrão não é compatível com o teste") }
        let temporaryDirectory = ProcessInfo.processInfo.environment["VOLTRA_TEST_TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let firstPath = temporaryDirectory.appendingPathComponent("voltra-concurrent-a-\(UUID().uuidString).wav")
        let secondPath = temporaryDirectory.appendingPathComponent("voltra-concurrent-b-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: firstPath); try? FileManager.default.removeItem(at: secondPath) }
        func writeTone(_ frequency: Double, to path: URL) throws {
            var wav = Data()
            func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
            let frames = 44100 * 12
            wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 4)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
            append(UInt32(16)); append(UInt16(1)); append(UInt16(2)); append(UInt32(44100)); append(UInt32(44100 * 4)); append(UInt16(4)); append(UInt16(16))
            wav.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 4))
            for frame in 0..<frames { let sample = Int16(1200 * sin(2 * Double.pi * frequency * Double(frame) / 44100)); append(sample); append(sample) }
            try wav.write(to: path)
        }
        try writeTone(440, to: firstPath)
        let observeCombined = ProcessInfo.processInfo.environment["VOLTRA_CONCURRENT_SELF_PROBE"] == "1"
        try writeTone(observeCombined ? 880 : 440, to: secondPath)
        func startSource(_ path: URL) throws -> Process {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); process.arguments = [path.path]
            try process.run(); return process
        }
        let first = try startSource(firstPath); defer { if first.isRunning { first.terminate(); first.waitUntilExit() } }
        let second = try startSource(secondPath); defer { if second.isRunning { second.terminate(); second.waitUntilExit() } }
        func object(for pid: pid_t) throws -> AudioObjectID {
            var object: AudioObjectID = 0
            let deadline = Date().addingTimeInterval(4)
            repeat {
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var pid = pid, size = UInt32(MemoryLayout<AudioObjectID>.size)
                _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
                if object != 0 { return object }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline
            throw XCTSkip("Processo de áudio não apareceu")
        }
        let firstObject = try object(for: first.processIdentifier), secondObject = try object(for: second.processIdentifier)
        XCTAssertNotEqual(firstObject, secondObject)
        let firstTap = ProcessTap(), secondTap = ProcessTap()
        firstTap.setGain(0.25, muted: false); secondTap.setGain(0.75, muted: false)
        try firstTap.start(processes: [firstObject], output: output); defer { firstTap.stop() }
        try secondTap.start(processes: [secondObject], output: output); defer { secondTap.stop() }
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertGreaterThan(firstTap.diagnostics.1, 0.001)
        XCTAssertGreaterThan(secondTap.diagnostics.1, 0.001)
        XCTAssertEqual(firstTap.diagnostics.2 / firstTap.diagnostics.1, 0.25, accuracy: 0.02)
        XCTAssertEqual(secondTap.diagnostics.2 / secondTap.diagnostics.1, 0.75, accuracy: 0.02)
        func amplitudes() throws -> (Double, Double) {
            let captured = try SelfOutputProbe.capture()
            guard captured.frames > 4096 else { throw XCTSkip("A saída do próprio processo não forneceu quadros suficientes") }
            let start = 256, count = Int(captured.frames) - 512
            func amplitude(_ frequency: Double) -> Double {
                var real = 0.0, imaginary = 0.0
                for i in 0..<count {
                    let sample = Double(captured.samples[(start + i) * 2])
                    let phase = 2 * Double.pi * frequency * Double(i) / captured.sampleRate
                    real += sample * cos(phase); imaginary -= sample * sin(phase)
                }
                return 2 * hypot(real, imaginary) / Double(count)
            }
            return (amplitude(440), amplitude(880))
        }
        let before = try observeCombined ? amplitudes() : (0, 0)
        if observeCombined {
            XCTAssertGreaterThan(before.0, 0.003)
            XCTAssertGreaterThan(before.1, 0.01)
        }
        firstTap.setGain(0.25, muted: true)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(firstTap.diagnostics.2, 0, accuracy: 0.00001)
        XCTAssertGreaterThan(secondTap.diagnostics.2, 0.001)
        if observeCombined {
            let after = try amplitudes()
            print("VOLTRA_CONCURRENT_SELF before=\(before) after=\(after)")
            XCTAssertLessThan(after.0, before.0 * 0.15)
            XCTAssertEqual(after.1, before.1, accuracy: 0.003)
            firstTap.setGain(0.25, muted: false)
            Thread.sleep(forTimeInterval: 0.3)
            let restored = try amplitudes()
            print("VOLTRA_CONCURRENT_RESTORED \(restored)")
            XCTAssertEqual(restored.0, before.0, accuracy: 0.003)
            XCTAssertEqual(restored.1, before.1, accuracy: 0.003)
        }
        if ProcessInfo.processInfo.environment["VOLTRA_OVERLAP_TEST"] == "1" {
            let duplicate = ProcessTap()
            duplicate.setGain(0.5, muted: false)
            try duplicate.start(processes: [firstObject], output: output)
            defer { duplicate.stop() }
            Thread.sleep(forTimeInterval: 0.5)
            print("VOLTRA_OVERLAP_DIAGNOSTICS callbacks=\(duplicate.diagnostics.0) input=\(duplicate.diagnostics.1) output=\(duplicate.diagnostics.2)")
            XCTAssertGreaterThan(duplicate.diagnostics.0, 0, "A segunda captura não iniciou")
        }
    }
}
