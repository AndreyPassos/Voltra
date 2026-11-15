import XCTest
@testable import Voltra
final class LoginItemTests: XCTestCase {
    final class FakeLoginItem: LoginItemManaging {
        var status: LoginItemState = .disabled
        var shouldFail = false
        func register() throws { if shouldFail { throw Failure.denied }; status = .enabled }
        func unregister() throws { if shouldFail { throw Failure.denied }; status = .disabled }
        enum Failure: Error { case denied }
    }
    func testEnableDisableAndFailureReflectSystemState() {
        let service = FakeLoginItem()
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        XCTAssertTrue(controller.enabled)
        controller.setEnabled(false)
        XCTAssertFalse(controller.enabled)
        service.shouldFail = true
        controller.setEnabled(true)
        XCTAssertFalse(controller.enabled)
        XCTAssertNotNil(controller.message)
    }
    func testPendingApprovalIsExplained() {
        let service = FakeLoginItem()
        service.status = .requiresApproval
        let controller = LoginItemController(service: service)
        XCTAssertTrue(controller.enabled)
        XCTAssertNotNil(controller.message)
        controller.setEnabled(false)
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(service.status, .disabled)
    }
}

final class LoginItemIntegrationTests: XCTestCase {
    func testRegisterAndRemoveIsolatedApplication() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_LOGIN_TEST"] == "1" else { throw XCTSkip("Teste de inicialização desativado") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoltraLogin-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("VoltraLoginProbe.app/Contents")
        let executable = bundle.appendingPathComponent("MacOS/VoltraLoginProbe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let identifier = "com.voltra.test-login." + UUID().uuidString
        let plist: [String: Any] = ["CFBundleExecutable": "VoltraLoginProbe", "CFBundleIdentifier": identifier, "CFBundleName": "Voltra Login Test", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/LoginProbe.swift")
        func run(_ path: String, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process(); let output = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = output; process.standardError = output
            try process.run(); process.waitUntilExit()
            return (process.terminationStatus, String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }
        let compile = try run("/usr/bin/xcrun", ["swiftc", source.path, "-o", executable.path])
        XCTAssertEqual(compile.0, 0, compile.1)
        let signed = try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.deletingLastPathComponent().path])
        XCTAssertEqual(signed.0, 0, signed.1)
        defer { _ = try? run(executable.path, ["--cleanup"]); try? FileManager.default.removeItem(at: root) }
        let result = try run(executable.path, [])
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertTrue(result.1.contains("registered-status="), result.1)
        XCTAssertTrue(result.1.contains("unregistered-status="), result.1)
    }
}
