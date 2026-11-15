import XCTest
@testable import Voltra
final class AutomationHistoryTests: XCTestCase {
    func testHistoryIsBoundedAndPreservesMostRecent() {
        let records = (0..<60).map { i in AutomationRecord(id: UUID(), date: Date(timeIntervalSince1970: Double(i)), profileName: "P\(i)", trigger: "Dispositivo", succeeded: true) }
        let limited = AutomationHistory.newest(records, limit: 50)
        XCTAssertEqual(limited.count, 50)
        XCTAssertEqual(limited.first?.profileName, "P59")
        XCTAssertEqual(limited.last?.profileName, "P10")
    }
    func testEarlierHistoryWithoutDetailStillDecodes() throws {
        let json = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"date\":0,\"profileName\":\"Trabalho\",\"trigger\":\"Horário\",\"succeeded\":true}"
        let record = try JSONDecoder().decode(AutomationRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.detail)
        XCTAssertTrue(record.succeeded)
    }
    func testKnownFailureDetailUsesCurrentLanguageAndLegacyTextIsPreserved() throws {
        let key = "Os dispositivos do perfil não estão disponíveis. Nenhuma alteração foi aplicada."
        let record = AutomationRecord(id: UUID(), date: Date(timeIntervalSince1970: 100), profileName: "Work", trigger: "Horário", succeeded: false, detail: "original", detailKey: key)
        let data = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(AutomationRecord.self, from: data)
        XCTAssertEqual(restored.displayDetail { _ in "Devices unavailable" }, "Devices unavailable")
        XCTAssertEqual(restored.displayDetail { $0 }, key)
        let legacy = AutomationRecord(id: UUID(), date: Date(), profileName: "Work", trigger: "Horário", succeeded: false, detail: "legacy")
        XCTAssertEqual(legacy.displayDetail { _ in "translated" }, "legacy")
    }
    func testFailureCodeRemainsAvailableWhenChangingLanguage() throws {
        let key = "Não foi possível alterar o dispositivo (erro %d)."
        let record = AutomationRecord(id: UUID(), date: Date(), profileName: "Work", trigger: "Dispositivo", succeeded: false, detail: "original", detailKey: key, detailCode: -50)
        let restored = try JSONDecoder().decode(AutomationRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.displayDetail { _ in "Could not change device (error %d)." }, "Could not change device (error -50).")
        XCTAssertEqual(restored.displayDetail { $0 }, "Não foi possível alterar o dispositivo (erro -50).")
    }
    func testScheduledUnavailableProfilePersistsLocalizableFailureKey() throws {
        let suite = "VoltraHistoryFailure-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        let now = Date()
        let service = AudioService(defaults: defaults, startTimer: false, now: { now })
        let profile = AudioProfile(id: UUID(), name: "Unavailable", inputUID: "missing-input", outputUID: "missing-output", volume: nil, appMix: nil)
        service.profiles.append(profile)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        service.addScheduledRule(hour: try XCTUnwrap(parts.hour), minute: try XCTUnwrap(parts.minute), profileID: profile.id)
        service.refresh()
        let deadline = Date().addingTimeInterval(5)
        while service.automationHistory.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let record = try XCTUnwrap(service.automationHistory.first)
        XCTAssertFalse(record.succeeded)
        XCTAssertEqual(record.detailKey, "Os dispositivos do perfil não estão disponíveis. Nenhuma alteração foi aplicada.")
        XCTAssertEqual(AutomationHistoryStore(defaults: defaults).load().first?.detailKey, record.detailKey)
    }
    func testHistoryPersists() {
        let suite = "VoltraHistory-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = [AutomationRecord(id: UUID(), date: Date(timeIntervalSince1970: 100), profileName: "Trabalho", trigger: "Aplicativo", succeeded: false, detail: "Saída indisponível")]
        let store = AutomationHistoryStore(defaults: defaults)
        store.save(history)
        XCTAssertEqual(store.load(), history)
    }
}
