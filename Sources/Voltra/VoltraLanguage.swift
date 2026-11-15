import Foundation

enum VoltraLanguage {
    static func resolve(_ preference: String, preferred: [String] = Locale.preferredLanguages) -> String {
        switch preference {
        case "pt", "en": return preference
        case "system":
            let primary = preferred.first?.lowercased().replacingOccurrences(of: "_", with: "-") ?? ""
            return primary == "pt" || primary.hasPrefix("pt-") ? "pt" : "en"
        default: return "en"
        }
    }
    static var current: String { resolve(UserDefaults.standard.string(forKey: "languagePreference") ?? "system") }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: current), arguments: arguments)
    }
    static func text(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: current, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
