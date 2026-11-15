import XCTest
import CoreAudio
@testable import Voltra

final class HardwareIntegrationTests: XCTestCase {
    func testRealDefaultSwitchAndRestore() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_HARDWARE_TEST"] == "1" else { throw XCTSkip("Teste de hardware desativado") }
        let suite = "VoltraHardware-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let savedPreferences = DevicePreferences.load(from: defaults)
        let service = AudioService(defaults: defaults, startTimer: false)
        let oldInput = service.defaultInput
        let oldOutput = service.defaultOutput
        service.automatic = false
        defer {
            service.automatic = false
            service.setDefault(oldInput, input: true)
            service.setDefault(oldOutput, input: false)
            savedPreferences.save(to: defaults)
        }
        let devices = service.devices
        guard let builtInInput = devices.first(where: { $0.input && $0.builtIn }),
              let builtInOutput = devices.first(where: { $0.output && $0.builtIn }),
              let headsetOutput = devices.first(where: { $0.id == oldOutput && !$0.builtIn && $0.output }),
              let headsetInput = devices.first(where: { $0.input && !$0.builtIn && $0.name == headsetOutput.name }) else { throw XCTSkip("Dispositivos físicos esperados não estão disponíveis") }
        service.setPreferredOutput(headsetOutput.uid)
        XCTAssertEqual(service.preferredInputUID, headsetInput.uid)
        service.devices = [builtInInput, builtInOutput]
        service.automatic = true
        service.applyPolicy()
        XCTAssertEqual(service.defaultInput, builtInInput.id)
        XCTAssertEqual(service.defaultOutput, builtInOutput.id)
        service.devices = devices
        service.applyPolicy()
        XCTAssertEqual(service.defaultInput, headsetInput.id)
        XCTAssertEqual(service.defaultOutput, headsetOutput.id)
        service.automatic = false
        let profile = AudioProfile(id: UUID(), name: "Teste", inputUID: builtInInput.uid, outputUID: builtInOutput.uid, volume: nil, appMix: nil)
        service.profiles.append(profile)
        XCTAssertTrue(service.applyProfile(profile))
        XCTAssertEqual(service.defaultInput, builtInInput.id)
        XCTAssertEqual(service.defaultOutput, builtInOutput.id)
        let missing = AudioProfile(id: UUID(), name: "Ausente", inputUID: "missing", outputUID: headsetOutput.uid, volume: nil, appMix: nil)
        service.profiles.append(missing)
        XCTAssertFalse(service.applyProfile(missing))
        XCTAssertEqual(service.defaultInput, builtInInput.id)
        XCTAssertEqual(service.defaultOutput, builtInOutput.id)
        XCTAssertNotNil(service.error)
    }
    func testScheduledProfileAppliesOnceOnRealDevices() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_HARDWARE_TEST"] == "1" else { throw XCTSkip("Teste de hardware desativado") }
        let suite = "VoltraScheduledHardware-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar.current
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12, minute: 0, second: 59))!
        let service = AudioService(defaults: defaults, startTimer: false, now: { now })
        let input = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultInput }))
        let output = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultOutput }))
        let marker = AppMix(volume: 0.21, muted: true)
        let profile = AudioProfile(id: UUID(), name: "Agendamento", inputUID: input.uid, outputUID: output.uid, volume: nil, appMix: ["scheduled-marker": marker])
        service.profiles.append(profile)
        service.addScheduledRule(hour: 12, minute: 0, profileID: profile.id)
        service.refresh()
        let deadline = Date().addingTimeInterval(5)
        while service.appSettings["scheduled-marker"] == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(service.appSettings["scheduled-marker"], marker)
        XCTAssertEqual(service.automationHistory.first?.trigger, "Horário")
        XCTAssertEqual(service.automationHistory.first?.succeeded, true)
        service.appSettings.removeValue(forKey: "scheduled-marker")
        service.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertNil(service.appSettings["scheduled-marker"])
    }
    func testMissedScheduleAppliesMostRecentProfileOnRealDevices() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_HARDWARE_TEST"] == "1" else { throw XCTSkip("Teste de hardware desativado") }
        let suite = "VoltraScheduledResume-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = Calendar.current
        var clock = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 8))!
        let service = AudioService(defaults: defaults, startTimer: false, now: { clock })
        let input = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultInput }))
        let output = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultOutput }))
        let earlier = AudioProfile(id: UUID(), name: "Earlier", inputUID: input.uid, outputUID: output.uid, volume: nil, appMix: ["marker": AppMix(volume: 0.2)])
        let latest = AudioProfile(id: UUID(), name: "Latest", inputUID: input.uid, outputUID: output.uid, volume: nil, appMix: ["marker": AppMix(volume: 0.7)])
        service.profiles.append(contentsOf: [earlier, latest])
        service.addScheduledRule(hour: 9, minute: 0, profileID: earlier.id)
        service.addScheduledRule(hour: 10, minute: 0, profileID: latest.id)
        clock = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10, minute: 30))!
        service.refresh()
        let deadline = Date().addingTimeInterval(5)
        while service.automationHistory.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(service.activeProfileID, latest.id)
        XCTAssertEqual(service.appSettings["marker"]?.volume, 0.7)
        XCTAssertEqual(service.automationHistory.first?.profileName, "Latest")
        service.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(service.automationHistory.count, 1)
    }
    func testActiveProfileTracksRealVolumeWithoutChangingOtherProfile() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_HARDWARE_VOLUME_TEST"] == "1" else { throw XCTSkip("Teste de volume desativado") }
        let suite = "VoltraActiveVolume-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AudioService(defaults: defaults, startTimer: false)
        guard service.volumeAvailable else { throw XCTSkip("Saída atual não oferece controle de volume") }
        let original = service.volume
        let probe = original > 0.1 ? original - 0.05 : original + 0.05
        defer { _ = service.setVolume(original) }
        let first = try XCTUnwrap(service.profiles.first)
        service.saveProfile(named: "Second test profile")
        let second = try XCTUnwrap(service.profiles.first(where: { $0.name == "Second test profile" }))
        XCTAssertTrue(service.setVolume(probe))
        XCTAssertEqual(try XCTUnwrap(service.profiles.first(where: { $0.id == second.id })?.volume), probe, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(service.profiles.first(where: { $0.id == first.id })?.volume), original, accuracy: 0.02)
        XCTAssertTrue(service.applyProfile(first))
        XCTAssertEqual(service.volume, original, accuracy: 0.02)
        let savedSecond = try XCTUnwrap(service.profiles.first(where: { $0.id == second.id }))
        XCTAssertEqual(try XCTUnwrap(savedSecond.volume), probe, accuracy: 0.02)
        XCTAssertTrue(service.applyProfile(savedSecond))
        XCTAssertEqual(service.volume, probe, accuracy: 0.02)
    }
    func testSystemVolumeOnRealOutputAndRestore() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_HARDWARE_VOLUME_TEST"] == "1" else { throw XCTSkip("Teste de volume desativado") }
        let suite = "VoltraVolume-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AudioService(defaults: defaults, startTimer: false)
        guard service.volumeAvailable else { throw XCTSkip("Saída atual não oferece controle de volume") }
        let original = service.volume
        let probe: Float = original > 0.05 ? original - 0.03 : original + 0.03
        defer { service.setVolume(original) }
        service.setVolume(probe)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.volume, probe, accuracy: 0.02)
        if service.muteAvailable {
            let originalMute = service.muted
            defer { if service.muted != originalMute { service.toggleMute() } }
            service.toggleMute()
            XCTAssertEqual(service.muted, !originalMute)
        }
    }
    func testUnsupportedProfileOutputDoesNotChangeDefaults() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_HARDWARE_TEST"] == "1" else { throw XCTSkip("Teste de hardware desativado") }
        let suite = "VoltraProfilePreflight-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AudioService(defaults: defaults, startTimer: false)
        let input = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultInput }))
        let output = try XCTUnwrap(service.devices.first(where: { $0.output && $0.builtIn }))
        let originalInput = service.defaultInput, originalOutput = service.defaultOutput
        let active = service.activeProfileID
        let uid = "com.voltra.aggregate.test." + UUID().uuidString
        let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "Voltra Preflight Test", kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceMainSubDeviceKey: output.uid, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]]]
        var aggregate: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate)
        XCTAssertEqual(status, noErr)
        guard status == noErr else { return }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }
        for element in 0...2 {
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(element))
            var writable: DarwinBoolean = false
            if AudioObjectHasProperty(aggregate, &property) && AudioObjectIsPropertySettable(aggregate, &property, &writable) == noErr && writable.boolValue {
                throw XCTSkip("Dispositivo agregado oferece volume gravável")
            }
        }
        service.devices.append(AudioDevice(id: aggregate, uid: uid, name: "Test", input: false, output: true, builtIn: false))
        let profile = AudioProfile(id: UUID(), name: "Unsupported", inputUID: input.uid, outputUID: uid, volume: 0.5, appMix: [:])
        service.profiles.append(profile)
        XCTAssertFalse(service.applyProfile(profile))
        XCTAssertEqual(service.defaultInput, originalInput)
        XCTAssertEqual(service.defaultOutput, originalOutput)
        XCTAssertEqual(service.activeProfileID, active)
        XCTAssertNotNil(service.error)
    }
    func testConnectionAutomationWithRealCoreAudioDeviceEvent() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_HARDWARE_TEST"] == "1" else { throw XCTSkip("Teste de hardware desativado") }
        let suite = "VoltraEvent-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AudioService(defaults: defaults, startTimer: false)
        let input = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultInput }))
        let output = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultOutput }))
        let builtin = try XCTUnwrap(service.devices.first(where: { $0.output && $0.builtIn }))
        let profile = AudioProfile(id: UUID(), name: "Evento", inputUID: input.uid, outputUID: output.uid, volume: nil, appMix: ["device-event-marker": AppMix(volume: 0.42, muted: false)])
        service.profiles.append(profile)
        let uid = "com.voltra.testevent." + UUID().uuidString
        service.addRule(deviceUID: uid, profileID: profile.id)
        let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "Voltra Test Device", kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceMainSubDeviceKey: builtin.uid, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: builtin.uid]]]
        var aggregate: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate)
        XCTAssertEqual(status, noErr)
        guard status == noErr else { return }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }
        let deadline = Date().addingTimeInterval(8)
        while service.appSettings["device-event-marker"] == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(service.appSettings["device-event-marker"]?.volume, 0.42)
        XCTAssertEqual(service.defaultInput, input.id)
        XCTAssertEqual(service.defaultOutput, output.id)
    }
    func testExternalVolumeChangeIsObservedWithoutPolling() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_HARDWARE_VOLUME_TEST"] == "1" else { throw XCTSkip("Teste de volume desativado") }
        let suite = "VoltraObserver-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let observer = AudioService(defaults: defaults, startTimer: false)
        let mutator = AudioService(defaults: defaults, startTimer: false)
        guard observer.volumeAvailable else { throw XCTSkip("Saída atual não oferece controle de volume") }
        let original = mutator.volume
        let probe: Float = original > 0.05 ? original - 0.03 : original + 0.03
        defer { mutator.setVolume(original) }
        mutator.setVolume(probe)
        let deadline = Date().addingTimeInterval(1.2)
        while abs(observer.volume - probe) > 0.02 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(observer.volume, probe, accuracy: 0.02)
    }
}
