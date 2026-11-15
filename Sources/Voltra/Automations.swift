import Foundation
struct ConnectionRule: Codable, Equatable, Identifiable {
    let id: UUID
    var deviceUID: String
    var profileID: UUID
    var enabled: Bool
}
struct AutomationStore {
    let defaults: UserDefaults
    func load() -> [ConnectionRule] { guard let data = defaults.data(forKey: "connectionRules") else { return [] }; return (try? JSONDecoder().decode([ConnectionRule].self, from: data)) ?? [] }
    func save(_ rules: [ConnectionRule]) { if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "connectionRules") } }
}
struct AppLaunchRule: Codable, Equatable, Identifiable {
    let id: UUID
    var bundleID: String
    var profileID: UUID
    var enabled: Bool
}
struct AppLaunchRuleStore {
    let defaults: UserDefaults
    func load() -> [AppLaunchRule] { guard let data = defaults.data(forKey: "appLaunchRules") else { return [] }; return (try? JSONDecoder().decode([AppLaunchRule].self, from: data)) ?? [] }
    func save(_ rules: [AppLaunchRule]) { if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "appLaunchRules") } }
}
struct ScheduledRule: Codable, Equatable, Identifiable {
    let id: UUID
    var hour: Int
    var minute: Int
    var profileID: UUID
    var enabled: Bool
}
struct ScheduledRuleStore {
    let defaults: UserDefaults
    func load() -> [ScheduledRule] { guard let data = defaults.data(forKey: "scheduledRules") else { return [] }; return (try? JSONDecoder().decode([ScheduledRule].self, from: data)) ?? [] }
    func save(_ rules: [ScheduledRule]) { if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "scheduledRules") } }
}
struct DeferredDevicePolicy {
    private var needed = false
    mutating func enqueue(needsDevicePolicy: Bool) { needed = needed || needsDevicePolicy }
    mutating func take() -> Bool { defer { needed = false }; return needed }
}
struct ScheduledBatch {
    var day: String
    var rules: [ScheduledRule]
}
struct ScheduleQueue {
    private var pending: ScheduledBatch?
    private var lastObserved: Date?
    mutating func capture(rules: [ScheduledRule], date: Date, calendar: Calendar, lastFired: [String: String], availableProfiles: Set<UUID>) -> Bool {
        guard pending == nil else { return false }
        let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let currentMinuteBoundary = minuteStart.addingTimeInterval(-0.001)
        let lowerBound = min(lastObserved.flatMap { $0 <= date ? $0 : nil } ?? currentMinuteBoundary, currentMinuteBoundary)
        lastObserved = date
        var candidates: [(rule: ScheduledRule, occurrence: Date)] = []
        for rule in rules where rule.enabled && availableProfiles.contains(rule.profileID) && (0...23).contains(rule.hour) && (0...59).contains(rule.minute) {
            let components = DateComponents(hour: rule.hour, minute: rule.minute, second: 0)
            guard let occurrence = calendar.nextDate(after: date.addingTimeInterval(0.001), matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .backward), occurrence > lowerBound else { continue }
            candidates.append((rule, occurrence))
        }
        guard let latest = candidates.map(\.occurrence).max() else { return false }
        let day = AutomationPolicy.dayKey(latest, calendar: calendar)
        let due = candidates.filter { $0.occurrence == latest && lastFired[$0.rule.id.uuidString] != day }.map(\.rule)
        guard !due.isEmpty else { return false }
        pending = ScheduledBatch(day: day, rules: due)
        return true
    }
    mutating func take() -> ScheduledBatch? { defer { pending = nil }; return pending }
}
struct RunningApp: Identifiable, Equatable { let id: String; let name: String }
enum AutomationPolicy {
    static func moving<Rule: Identifiable>(_ rules: [Rule], id: UUID, offset: Int) -> [Rule] where Rule.ID == UUID {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + offset) else { return rules }
        var result = rules
        result.swapAt(index, index + offset)
        return result
    }
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(parts.era ?? 0)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
    static func dueSchedule(rules: [ScheduledRule], date: Date, calendar: Calendar, lastFired: [String: String], availableProfiles: Set<UUID>) -> ScheduledRule? {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let day = dayKey(date, calendar: calendar)
        return rules.first { $0.enabled && $0.hour == parts.hour && $0.minute == parts.minute && availableProfiles.contains($0.profileID) && lastFired[$0.id.uuidString] != day }
    }
    static func profileForLaunch(rules: [AppLaunchRule], launched: Set<String>, availableProfiles: Set<UUID>) -> UUID? {
        rules.first { $0.enabled && launched.contains($0.bundleID) && availableProfiles.contains($0.profileID) }?.profileID
    }
    static func profileToActivate(rules: [ConnectionRule], connected: Set<String>, availableProfiles: Set<UUID>) -> UUID? {
        rules.first { $0.enabled && connected.contains($0.deviceUID) && availableProfiles.contains($0.profileID) }?.profileID
    }
}

struct AutomationRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let profileName: String
    let trigger: String
    let succeeded: Bool
    var detail: String? = nil
    var detailKey: String? = nil
    var detailCode: Int32? = nil
    func displayDetail(localize: (String) -> String) -> String? {
        if let detailKey {
            let translated = localize(detailKey)
            if let detailCode { return String(format: translated, detailCode) }
            return translated
        }
        return detail
    }
}
enum AutomationHistory {
    static func newest(_ records: [AutomationRecord], limit: Int = 50) -> [AutomationRecord] {
        Array(records.sorted { $0.date > $1.date }.prefix(max(0, limit)))
    }
}
struct AutomationHistoryStore {
    let defaults: UserDefaults
    func load() -> [AutomationRecord] {
        guard let data = defaults.data(forKey: "automationHistory"), let records = try? JSONDecoder().decode([AutomationRecord].self, from: data) else { return [] }
        return AutomationHistory.newest(records)
    }
    func save(_ records: [AutomationRecord]) {
        if let data = try? JSONEncoder().encode(AutomationHistory.newest(records)) { defaults.set(data, forKey: "automationHistory") }
    }
}
