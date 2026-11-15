import XCTest
import Carbon
@testable import Voltra
final class GlobalShortcutTests: XCTestCase {
    final class FakeBackend: GlobalShortcutRegistering {
        var registered: ShortcutKey?
        var rejected: ShortcutKey?
        func register(_ key: ShortcutKey, action: @escaping () -> Void) throws {
            if key == rejected { throw Failure.conflict }
            registered = key
        }
        func unregister() { registered = nil }
        enum Failure: Error { case conflict }
    }
    func testShortcutIsOptInAndPersists() {
        let suite = "VoltraShortcut-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeBackend()
        let controller = GlobalShortcutController(defaults: defaults, backend: backend, action: {})
        XCTAssertNil(backend.registered)
        controller.setEnabled(true)
        XCTAssertEqual(backend.registered, .m)
        controller.setKey(.v)
        XCTAssertEqual(backend.registered, .v)
        XCTAssertEqual(defaults.string(forKey: "shortcutKey"), "v")
        controller.setEnabled(false)
        XCTAssertNil(backend.registered)
    }
    func testConflictingChangeRestoresPreviousShortcut() {
        let suite = "VoltraShortcut-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeBackend()
        let controller = GlobalShortcutController(defaults: defaults, backend: backend, action: {})
        controller.setEnabled(true)
        backend.rejected = .v
        controller.setKey(.v)
        XCTAssertEqual(controller.key, .m)
        XCTAssertEqual(backend.registered, .m)
        XCTAssertNotNil(controller.message)
    }
    func testRealMacRegistrationAndCleanup() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_HOTKEY_TEST"] == "1" else { throw XCTSkip("Teste de atalho desativado") }
        let backend = CarbonGlobalShortcut()
        defer { backend.unregister() }
        let triggered = expectation(description: "hotkey callback")
        try backend.register(.s) { triggered.fulfill() }
        let competing = CarbonGlobalShortcut()
        defer { competing.unregister() }
        XCTAssertThrowsError(try competing.register(.s, action: {}))
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event), noErr)
        let actual = try XCTUnwrap(event)
        defer { ReleaseEvent(actual) }
        var id = EventHotKeyID(signature: 0x56544C52, id: 1)
        XCTAssertEqual(SetEventParameter(actual, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id), noErr)
        XCTAssertEqual(SendEventToEventTarget(actual, GetApplicationEventTarget()), noErr)
        wait(for: [triggered], timeout: 2)
    }
}
