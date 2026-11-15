import XCTest
@testable import Voltra

final class AppControlPreferencesTests: XCTestCase {
    func testAutomaticModeAndPerAppOverridesPersist() {
        let suite = "VoltraControlTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var prefs = AppControlPreferences.load(from: defaults)
        XCTAssertTrue(prefs.automatic)
        prefs.automatic = true
        prefs.disable("example.disabled")
        prefs.enable("example.manual")
        prefs.save(to: defaults)
        var restored = AppControlPreferences.load(from: defaults)
        XCTAssertTrue(restored.shouldControl("example.new"))
        XCTAssertTrue(restored.shouldControl("example.disabled"), "O modo automático deve controlar todos os aplicativos, inclusive antigos excluídos")
        restored.automatic = false
        XCTAssertFalse(restored.shouldControl("example.new"))
        XCTAssertTrue(restored.shouldControl("example.manual"))
        restored.disable("example.manual")
        XCTAssertFalse(restored.shouldControl("example.manual"))
    }
    func testLegacyPreferencesPreserveManualModeAndEnabledApplications() {
        let suite = "VoltraLegacyControl-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{\"automatic\":false,\"enabled\":[\"com.example.app\"]}".utf8), forKey: "appControlPreferences")
        let restored = AppControlPreferences.load(from: defaults)
        XCTAssertFalse(restored.automatic)
        XCTAssertTrue(restored.shouldControl("com.example.app"))
        XCTAssertFalse(restored.shouldControl("com.example.other"))
        defaults.set(Data("{\"enabled\":[\"com.example.app\"]}".utf8), forKey: "appControlPreferences")
        let older = AppControlPreferences.load(from: defaults)
        XCTAssertFalse(older.automatic)
        XCTAssertTrue(older.shouldControl("com.example.app"))
    }
    func testCorruptPreferencesAreBackedUpAndDoNotEnableAutomaticCapture() {
        let suite = "VoltraCorruptControl-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let damaged = Data([0xff, 0x00, 0x42])
        defaults.set(damaged, forKey: "appControlPreferences")
        let service = AudioService(defaults: defaults, startTimer: false)
        XCTAssertFalse(service.controlPreferences.automatic)
        XCTAssertEqual(defaults.data(forKey: "appControlPreferences.corruptBackup"), damaged)
        XCTAssertNotNil(service.error)
    }
    func testServiceRestoresManuallyEnabledAppsWithoutStartingInactiveApps() {
        let suite = "VoltraControlRestore-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = AppControlPreferences()
        preferences.automatic = false
        preferences.enable("example.inactive-app")
        preferences.disable("example.excluded-app")
        preferences.save(to: defaults)
        let service = AudioService(defaults: defaults, startTimer: false)
        XCTAssertTrue(service.desiredApps.contains("example.inactive-app"))
        XCTAssertFalse(service.controlledApps.contains("example.inactive-app"))
        XCTAssertFalse(service.desiredApps.contains("example.excluded-app"))
        XCTAssertFalse(service.controlPreferences.automatic)
    }
}
