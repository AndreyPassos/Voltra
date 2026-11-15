import XCTest
@testable import Voltra
final class ProfileTests: XCTestCase {
    func testDefaultProfileCreatedWhenNoneExist() {
        let suite = "VoltraDefaultProfile-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults)
        let created = store.createDefaultIfNeeded(name: "Default", inputUID: "mic", outputUID: "speakers", volume: 0.5, appMix: [:])
        XCTAssertEqual(created?.name, "Default")
        XCTAssertEqual(created?.inputUID, "mic")
        XCTAssertEqual(store.load().count, 1)
        XCTAssertNil(store.createDefaultIfNeeded(name: "Default", inputUID: "other", outputUID: "other", volume: nil, appMix: [:]))
        store.save([])
        XCTAssertNotNil(store.createDefaultIfNeeded(name: "Default", inputUID: "mic", outputUID: "speakers", volume: nil, appMix: [:]))
        XCTAssertEqual(store.load().count, 1)
    }
    func testDefaultCanExistBeforeDevicesAreAvailable() {
        let suite = "VoltraProfileNoDevices-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults)
        let profile = store.createDefaultIfNeeded(name: "Default", inputUID: "", outputUID: "", volume: nil, appMix: [:])
        XCTAssertNotNil(profile)
        XCTAssertEqual(store.load().count, 1)
    }
    func testRoundTripAndDelete() throws {
        let suite = "VoltraProfiles-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults)
        let profile = AudioProfile(id: UUID(), name: "Trabalho", inputUID: "mic", outputUID: "phones", volume: 0.35, appMix: ["com.example.app": AppMix(volume: 0.4, muted: true)])
        store.save([profile])
        XCTAssertEqual(store.load(), [profile])
        store.save([])
        XCTAssertEqual(store.load(), [])
    }
    func testOlderProfilesRemainReadableAndMuteIsSaved() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Old\",\"inputUID\":\"in\",\"outputUID\":\"out\"}".utf8)
        let old = try JSONDecoder().decode(AudioProfile.self, from: data)
        XCTAssertNil(old.outputMuted)
        let updated = old.withSnapshot(inputUID: "in", outputUID: "out", volume: 0.4, appMix: [:], outputMuted: true)
        XCTAssertEqual(try JSONDecoder().decode(AudioProfile.self, from: JSONEncoder().encode(updated)).outputMuted, true)
    }
    func testOutputCapabilitiesAreCheckedBeforeApplyingProfile() {
        XCTAssertNil(ProfileOutputPolicy.failure(volumeRequested: false, volumeAvailable: false, muteRequested: false, muteAvailable: false))
        XCTAssertEqual(ProfileOutputPolicy.failure(volumeRequested: true, volumeAvailable: false, muteRequested: false, muteAvailable: true), .volume)
        XCTAssertEqual(ProfileOutputPolicy.failure(volumeRequested: false, volumeAvailable: true, muteRequested: true, muteAvailable: false), .mute)
        XCTAssertNil(ProfileOutputPolicy.failure(volumeRequested: true, volumeAvailable: true, muteRequested: true, muteAvailable: true))
    }
    func testUnavailableOutputControlsArePreservedOnlyForSameDevice() {
        let profile = AudioProfile(id: UUID(), name: "Work", inputUID: "mic", outputUID: "speakers", volume: 0.5, appMix: [:], outputMuted: true)
        let temporary = profile.withObservedSnapshot(inputUID: "mic", outputUID: "speakers", volume: nil, appMix: [:], outputMuted: nil)
        XCTAssertEqual(temporary.volume, 0.5)
        XCTAssertEqual(temporary.outputMuted, true)
        let hdmi = profile.withObservedSnapshot(inputUID: "mic", outputUID: "hdmi", volume: nil, appMix: [:], outputMuted: nil)
        XCTAssertNil(hdmi.volume)
        XCTAssertNil(hdmi.outputMuted)
        XCTAssertEqual(hdmi.outputUID, "hdmi")
    }
    func testRefreshSnapshotPreservesIdentityAndName() {
        let old = AudioProfile(id: UUID(), name: "Reunião", inputUID: "a", outputUID: "b", volume: 0.1, appMix: nil)
        let updated = old.withSnapshot(inputUID: "mic", outputUID: "speaker", volume: 0.8, appMix: [:])
        XCTAssertEqual(updated.id, old.id)
        XCTAssertEqual(updated.name, old.name)
        XCTAssertEqual(updated.inputUID, "mic")
        XCTAssertEqual(updated.outputUID, "speaker")
        XCTAssertEqual(updated.volume, 0.8)
    }
    func testCorruptStorageDoesNotCrash() {
        let suite = "VoltraProfiles-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([0xFF]), forKey: "profiles")
        XCTAssertEqual(ProfileStore(defaults: defaults).load(), [])
    }
}

final class IsolatedServiceTests: XCTestCase {
    func testChangingOneAppPreservesOtherAppsMixAndRouteAfterRestart() throws {
        let suite = "VoltraIndependentApps-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        let service = AudioService(defaults: defaults, startTimer: false)
        let music = ActiveApp(id: "example.music", name: "Music", processes: [])
        let call = ActiveApp(id: "example.call", name: "Call", processes: [])
        service.setAppMix(music, volume: 0.37, muted: false)
        service.setAppOutput(music, uid: "preferred-music-output")
        let expected = service.settings(for: music.id)
        service.setAppMix(call, volume: 0.81, muted: true)
        service.setAppOutput(call, uid: "preferred-call-output")
        XCTAssertEqual(service.settings(for: music.id), expected)
        let active = try XCTUnwrap(service.activeProfileID)
        XCTAssertEqual(service.profiles.first(where: { $0.id == active })?.appMix?[music.id], expected)
        let reopened = AudioService(defaults: defaults, startTimer: false)
        XCTAssertEqual(reopened.settings(for: music.id), expected)
        XCTAssertEqual(reopened.settings(for: call.id).volume, 0.81)
        XCTAssertEqual(reopened.settings(for: call.id).outputUID, "preferred-call-output")
    }
    func testOnlyActiveProfileReceivesAppChangesAndSelectionPersists() throws {
        let suite = "VoltraActiveProfile-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        let service = AudioService(defaults: defaults, startTimer: false)
        let original = try XCTUnwrap(service.profiles.first)
        XCTAssertEqual(service.activeProfileID, original.id)
        service.saveProfile(named: "Second")
        let second = try XCTUnwrap(service.profiles.first(where: { $0.name == "Second" }))
        XCTAssertEqual(service.activeProfileID, second.id)
        let app = ActiveApp(id: "example.profile-test", name: "Example", processes: [])
        service.setAppMix(app, volume: 0.35, muted: true)
        XCTAssertEqual(service.profiles.first(where: { $0.id == second.id })?.appMix?[app.id]?.volume, 0.35)
        XCTAssertNil(service.profiles.first(where: { $0.id == original.id })?.appMix?[app.id])
        XCTAssertEqual(defaults.string(forKey: "activeProfileID"), second.id.uuidString)
        XCTAssertTrue(service.applyProfile(original))
        XCTAssertEqual(service.activeProfileID, original.id)
        XCTAssertNil(service.appSettings[app.id])
        XCTAssertEqual(service.profiles.first(where: { $0.id == second.id })?.appMix?[app.id]?.volume, 0.35)
        let savedSecond = try XCTUnwrap(service.profiles.first(where: { $0.id == second.id }))
        XCTAssertTrue(service.applyProfile(savedSecond))
        XCTAssertEqual(service.appSettings[app.id]?.volume, 0.35)
        XCTAssertEqual(service.appSettings[app.id]?.muted, true)
        let reopened = AudioService(defaults: defaults, startTimer: false)
        XCTAssertEqual(reopened.activeProfileID, second.id)
        XCTAssertEqual(reopened.appSettings[app.id]?.volume, 0.35)
        XCTAssertEqual(reopened.appSettings[app.id]?.muted, true)
        service.deleteProfile(second)
        XCTAssertEqual(service.profiles.count, 1)
        XCTAssertEqual(service.activeProfileID, original.id)
    }
    func testAppOutputFollowsActiveProfileAcrossSwitchAndRestart() throws {
        let suite = "VoltraProfileRoute-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        let service = AudioService(defaults: defaults, startTimer: false)
        let initial = try XCTUnwrap(service.profiles.first)
        let app = ActiveApp(id: "example.profile-route", name: "Example", processes: [])
        service.setAppOutput(app, uid: "output-a")
        service.saveProfile(named: "Second")
        let second = try XCTUnwrap(service.profiles.first(where: { $0.name == "Second" }))
        service.setAppOutput(app, uid: "output-b")
        let firstSaved = try XCTUnwrap(service.profiles.first(where: { $0.id == initial.id }))
        let secondSaved = try XCTUnwrap(service.profiles.first(where: { $0.id == second.id }))
        XCTAssertEqual(firstSaved.appMix?[app.id]?.outputUID, "output-a")
        XCTAssertEqual(secondSaved.appMix?[app.id]?.outputUID, "output-b")
        XCTAssertTrue(service.applyProfile(firstSaved))
        XCTAssertEqual(service.settings(for: app.id).outputUID, "output-a")
        XCTAssertTrue(service.applyProfile(secondSaved))
        XCTAssertEqual(service.settings(for: app.id).outputUID, "output-b")
        let reopened = AudioService(defaults: defaults, startTimer: false)
        XCTAssertEqual(reopened.activeProfileID, second.id)
        XCTAssertEqual(reopened.settings(for: app.id).outputUID, "output-b")
        XCTAssertEqual(reopened.profiles.first(where: { $0.id == initial.id })?.appMix?[app.id]?.outputUID, "output-a")
    }
    func testLegacyProfileWithoutAppSettingsDoesNotInheritActiveMix() throws {
        let suite = "VoltraLegacyProfile-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        let service = AudioService(defaults: defaults, startTimer: false)
        let first = try XCTUnwrap(service.profiles.first)
        let app = ActiveApp(id: "example.legacy-mix", name: "Example", processes: [])
        service.setAppMix(app, volume: 0.2, muted: true)
        let legacy = AudioProfile(id: UUID(), name: "Legacy", inputUID: first.inputUID, outputUID: first.outputUID, volume: nil, appMix: nil)
        service.profiles.append(legacy)
        XCTAssertTrue(service.applyProfile(legacy))
        XCTAssertNil(service.appSettings[app.id])
        XCTAssertEqual(service.profiles.first(where: { $0.id == first.id })?.appMix?[app.id]?.volume, 0.2)
    }
    func testUnavailableProfileDoesNotReplaceActiveProfile() throws {
        let suite = "VoltraMissingProfile-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        let service = AudioService(defaults: defaults, startTimer: false)
        let active = try XCTUnwrap(service.profiles.first)
        let missing = AudioProfile(id: UUID(), name: "Missing", inputUID: "not-connected-input", outputUID: "not-connected-output", volume: 0.2, appMix: [:])
        service.profiles.append(missing)
        XCTAssertFalse(service.applyProfile(missing))
        XCTAssertEqual(service.activeProfileID, active.id)
        XCTAssertEqual(service.profiles.first(where: { $0.id == active.id }), active)
        service.profiles.removeLast()
        service.deleteProfile(active)
        XCTAssertEqual(service.profiles.count, 1)
    }
    func testInitialProfileCapturesOutputMuteWhenSupported() throws {
        let suite = "VoltraInitialMute-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        let service = AudioService(defaults: defaults, startTimer: false)
        guard service.muteAvailable else { throw XCTSkip("Saída sem controle de silêncio") }
        XCTAssertEqual(service.profiles.first?.outputMuted, service.muted)
    }
    func testServiceUsesInjectedPreferenceDomain() {
        let firstName = "VoltraFirst-" + UUID().uuidString
        let secondName = "VoltraSecond-" + UUID().uuidString
        let first = UserDefaults(suiteName: firstName)!
        let second = UserDefaults(suiteName: secondName)!
        defer { first.removePersistentDomain(forName: firstName); second.removePersistentDomain(forName: secondName) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: first)
        let service = AudioService(defaults: first, startTimer: false)
        service.preferredUID = "headset"
        XCTAssertEqual(first.string(forKey: "preferredOutputUID"), "headset")
        XCTAssertNil(second.string(forKey: "preferredOutputUID"))
    }
}
