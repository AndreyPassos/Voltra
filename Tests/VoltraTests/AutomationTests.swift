import XCTest
@testable import Voltra
final class AutomationTests: XCTestCase {
    func testConnectionChoosesFirstEnabledValidRule() {
        let one = UUID(), two = UUID()
        let rules = [ConnectionRule(id: UUID(), deviceUID: "headset", profileID: one, enabled: false), ConnectionRule(id: UUID(), deviceUID: "headset", profileID: two, enabled: true)]
        XCTAssertEqual(AutomationPolicy.profileToActivate(rules: rules, connected: ["headset"], availableProfiles: [one, two]), two)
        XCTAssertNil(AutomationPolicy.profileToActivate(rules: rules, connected: ["other"], availableProfiles: [one, two]))
        XCTAssertNil(AutomationPolicy.profileToActivate(rules: rules, connected: ["headset"], availableProfiles: [one]))
    }
    func testPriorityMoveClampsAtBoundaries() {
        let rules = (0..<2).map { _ in ConnectionRule(id: UUID(), deviceUID: "d", profileID: UUID(), enabled: true) }
        XCTAssertEqual(AutomationPolicy.moving(rules, id: rules[1].id, offset: -1), [rules[1], rules[0]])
        XCTAssertEqual(AutomationPolicy.moving(rules, id: rules[0].id, offset: -1), rules)
    }
    func testPriorityCanReorderApplicationAndScheduleRules() {
        let profile = UUID()
        let apps = [AppLaunchRule(id: UUID(), bundleID: "a", profileID: profile, enabled: true), AppLaunchRule(id: UUID(), bundleID: "b", profileID: profile, enabled: true)]
        let schedules = [ScheduledRule(id: UUID(), hour: 9, minute: 0, profileID: profile, enabled: true), ScheduledRule(id: UUID(), hour: 9, minute: 0, profileID: profile, enabled: true)]
        XCTAssertEqual(AutomationPolicy.moving(apps, id: apps[1].id, offset: -1), [apps[1], apps[0]])
        XCTAssertEqual(AutomationPolicy.moving(schedules, id: schedules[1].id, offset: -1), [schedules[1], schedules[0]])
    }
    func testApplicationLaunchRuleRequiresEnabledRuleAndExistingProfile() {
        let first = UUID(), second = UUID()
        let rules = [AppLaunchRule(id: UUID(), bundleID: "com.example.meeting", profileID: first, enabled: false), AppLaunchRule(id: UUID(), bundleID: "com.example.meeting", profileID: second, enabled: true)]
        XCTAssertEqual(AutomationPolicy.profileForLaunch(rules: rules, launched: ["com.example.meeting"], availableProfiles: [first, second]), second)
        XCTAssertNil(AutomationPolicy.profileForLaunch(rules: rules, launched: ["other"], availableProfiles: [first, second]))
        XCTAssertNil(AutomationPolicy.profileForLaunch(rules: rules, launched: ["com.example.meeting"], availableProfiles: [first]))
    }
    func testApplicationLaunchRulesPersist() {
        let suite = "VoltraAppRules-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let rules = [AppLaunchRule(id: UUID(), bundleID: "com.example", profileID: UUID(), enabled: true)]
        let store = AppLaunchRuleStore(defaults: defaults)
        store.save(rules)
        XCTAssertEqual(store.load(), rules)
    }
    func testScheduledRuleRunsOncePerLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 22, minute: 0))!
        let profile = UUID()
        let rule = ScheduledRule(id: UUID(), hour: 22, minute: 0, profileID: profile, enabled: true)
        let day = AutomationPolicy.dayKey(date, calendar: calendar)
        XCTAssertEqual(AutomationPolicy.dueSchedule(rules: [rule], date: date, calendar: calendar, lastFired: [:], availableProfiles: [profile]), rule)
        XCTAssertNil(AutomationPolicy.dueSchedule(rules: [rule], date: date, calendar: calendar, lastFired: [rule.id.uuidString: day], availableProfiles: [profile]))
        XCTAssertNil(AutomationPolicy.dueSchedule(rules: [rule], date: date, calendar: calendar, lastFired: [:], availableProfiles: []))
    }
    func testScheduledEventSurvivesMinuteBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 22, minute: 0, second: 59))!
        let profile = UUID()
        let rule = ScheduledRule(id: UUID(), hour: 22, minute: 0, profileID: profile, enabled: true)
        var queue = ScheduleQueue()
        XCTAssertTrue(queue.capture(rules: [rule], date: date, calendar: calendar, lastFired: [:], availableProfiles: [profile]))
        let event = queue.take()
        XCTAssertEqual(event?.rules.first, rule)
        XCTAssertEqual(event?.day, AutomationPolicy.dayKey(date, calendar: calendar))
        XCTAssertNil(queue.take())
    }
    func testScheduleCatchesMostRecentMissedTimeAndKeepsPriority() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ hour: Int, _ minute: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: hour, minute: minute))! }
        let profile = UUID()
        let early = ScheduledRule(id: UUID(), hour: 9, minute: 0, profileID: profile, enabled: true)
        let latest = ScheduledRule(id: UUID(), hour: 10, minute: 0, profileID: profile, enabled: true)
        let tied = ScheduledRule(id: UUID(), hour: 10, minute: 0, profileID: profile, enabled: true)
        var queue = ScheduleQueue()
        XCTAssertFalse(queue.capture(rules: [early, latest, tied], date: date(8, 0), calendar: calendar, lastFired: [:], availableProfiles: [profile]))
        XCTAssertTrue(queue.capture(rules: [early, latest, tied], date: date(10, 30), calendar: calendar, lastFired: [:], availableProfiles: [profile]))
        XCTAssertEqual(queue.take()?.rules, [latest, tied])
    }
    func testScheduleCatchUpAcrossMidnightUsesOccurrenceDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 22))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 1))!
        let profile = UUID()
        let rule = ScheduledRule(id: UUID(), hour: 23, minute: 0, profileID: profile, enabled: true)
        var queue = ScheduleQueue()
        XCTAssertFalse(queue.capture(rules: [rule], date: start, calendar: calendar, lastFired: [:], availableProfiles: [profile]))
        XCTAssertTrue(queue.capture(rules: [rule], date: end, calendar: calendar, lastFired: [:], availableProfiles: [profile]))
        XCTAssertEqual(queue.take()?.day, AutomationPolicy.dayKey(start, calendar: calendar))
    }
    func testPreviouslyFiredLatestScheduleDoesNotReapplyOlderSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ hour: Int, _ minute: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: hour, minute: minute))! }
        let profile = UUID()
        let early = ScheduledRule(id: UUID(), hour: 9, minute: 0, profileID: profile, enabled: true)
        let latest = ScheduledRule(id: UUID(), hour: 10, minute: 0, profileID: profile, enabled: true)
        var queue = ScheduleQueue()
        XCTAssertFalse(queue.capture(rules: [early, latest], date: date(8, 0), calendar: calendar, lastFired: [:], availableProfiles: [profile]))
        let fired = [latest.id.uuidString: AutomationPolicy.dayKey(date(10, 0), calendar: calendar)]
        XCTAssertFalse(queue.capture(rules: [early, latest], date: date(10, 30), calendar: calendar, lastFired: fired, availableProfiles: [profile]))
        XCTAssertNil(queue.take())
    }
    func testScheduleDoesNotInventNonexistentDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 55)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 30)))
        let profile = UUID()
        let rule = ScheduledRule(id: UUID(), hour: 2, minute: 30, profileID: profile, enabled: true)
        var queue = ScheduleQueue()
        XCTAssertFalse(queue.capture(rules: [rule], date: start, calendar: calendar, lastFired: [:], availableProfiles: [profile]))
        XCTAssertFalse(queue.capture(rules: [rule], date: end, calendar: calendar, lastFired: [:], availableProfiles: [profile]))
    }
    func testScheduleRunsAtMostOnceWhenDaylightSavingRepeatsTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let iso = ISO8601DateFormatter()
        let first = try XCTUnwrap(iso.date(from: "2026-11-01T05:30:00Z"))
        let second = try XCTUnwrap(iso.date(from: "2026-11-01T06:30:00Z"))
        let profile = UUID()
        let rule = ScheduledRule(id: UUID(), hour: 1, minute: 30, profileID: profile, enabled: true)
        var queue = ScheduleQueue()
        XCTAssertTrue(queue.capture(rules: [rule], date: first, calendar: calendar, lastFired: [:], availableProfiles: [profile]))
        let batch = try XCTUnwrap(queue.take())
        XCTAssertFalse(queue.capture(rules: [rule], date: second, calendar: calendar, lastFired: [rule.id.uuidString: batch.day], availableProfiles: [profile]))
    }
    func testScheduledRulePersistence() {
        let suite = "VoltraSchedule-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let rules = [ScheduledRule(id: UUID(), hour: 7, minute: 30, profileID: UUID(), enabled: true)]
        let store = ScheduledRuleStore(defaults: defaults)
        store.save(rules)
        XCTAssertEqual(store.load(), rules)
    }
    func testRuleStorageRoundTrip() {
        let suite = "VoltraRules-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let rules = [ConnectionRule(id: UUID(), deviceUID: "abc", profileID: UUID(), enabled: true)]
        let store = AutomationStore(defaults: defaults)
        store.save(rules)
        XCTAssertEqual(store.load(), rules)
    }
}

final class DeferredPolicyTests: XCTestCase {
    func testAppEventsDoNotTriggerDeviceFallback() {
        var batch = DeferredDevicePolicy()
        batch.enqueue(needsDevicePolicy: false)
        XCTAssertFalse(batch.take())
    }
    func testDeviceChangeSurvivesSubsequentAppEvents() {
        var batch = DeferredDevicePolicy()
        batch.enqueue(needsDevicePolicy: true)
        batch.enqueue(needsDevicePolicy: false)
        XCTAssertTrue(batch.take())
        XCTAssertFalse(batch.take())
    }
}
