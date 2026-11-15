import XCTest
@testable import Voltra
final class NotificationPolicyTests: XCTestCase {
    func testOnlyReportsRealChangesWhenEnabled() {
        XCTAssertNil(NotificationPolicy.message(enabled: false, previous: ["a"], current: ["a", "b"]))
        XCTAssertNil(NotificationPolicy.message(enabled: true, previous: nil, current: ["a"]))
        XCTAssertNil(NotificationPolicy.message(enabled: true, previous: ["a"], current: ["a"]))
        XCTAssertEqual(NotificationPolicy.message(enabled: true, previous: ["a"], current: ["a", "b"]), "Dispositivo de áudio conectado.")
        XCTAssertEqual(NotificationPolicy.message(enabled: true, previous: ["a", "b"], current: ["a"]), "Dispositivo de áudio desconectado.")
    }
}

final class NotificationPermissionTests: XCTestCase {
    final class FakeNotifications: AudioNotificationManaging {
        var completion: ((Bool) -> Void)?
        var messages: [String] = []
        func requestPermission(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
        func post(_ message: String) { messages.append(message) }
    }
    func testLatePermissionResponseCannotUndoDisable() {
        let suite = "VoltraNotifications-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifications = FakeNotifications()
        let service = AudioService(defaults: defaults, startTimer: false, notifications: notifications)
        service.setNotificationsEnabled(true)
        service.setNotificationsEnabled(false)
        notifications.completion?(true)
        XCTAssertFalse(service.notificationsEnabled)
        XCTAssertFalse(defaults.bool(forKey: "notificationsEnabled"))
    }
    func testDeniedPermissionReportsFailure() {
        let suite = "VoltraNotifications-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifications = FakeNotifications()
        let service = AudioService(defaults: defaults, startTimer: false, notifications: notifications)
        service.setNotificationsEnabled(true)
        notifications.completion?(false)
        XCTAssertFalse(service.notificationsEnabled)
        XCTAssertNotNil(service.error)
    }
}
