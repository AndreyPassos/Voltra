import Foundation

struct AppControlPreferences: Codable {
    var automatic = true
    private(set) var enabled: Set<String> = []
    private(set) var excluded: Set<String> = []

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Stored records without the newer automatic flag predate automatic capture.
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        enabled = try values.decodeIfPresent(Set<String>.self, forKey: .enabled) ?? []
        excluded = try values.decodeIfPresent(Set<String>.self, forKey: .excluded) ?? []
    }
    struct LoadResult {
        let preferences: AppControlPreferences
        let recoveredFromCorruption: Bool
    }
    static func loadState(from defaults: UserDefaults) -> LoadResult {
        guard let raw = defaults.object(forKey: "appControlPreferences") else { return LoadResult(preferences: Self(), recoveredFromCorruption: false) }
        if let data = raw as? Data, let result = try? JSONDecoder().decode(Self.self, from: data) {
            return LoadResult(preferences: result, recoveredFromCorruption: false)
        }
        if defaults.object(forKey: "appControlPreferences.corruptBackup") == nil { defaults.set(raw, forKey: "appControlPreferences.corruptBackup") }
        var safe = Self(); safe.automatic = false
        return LoadResult(preferences: safe, recoveredFromCorruption: true)
    }

    func shouldControl(_ id: String) -> Bool { automatic || enabled.contains(id) }
    mutating func enable(_ id: String) { enabled.insert(id); excluded.remove(id) }
    mutating func disable(_ id: String) { enabled.remove(id); excluded.insert(id) }
    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "appControlPreferences") }
    }
    static func load(from defaults: UserDefaults) -> Self {
        loadState(from: defaults).preferences
    }
}
