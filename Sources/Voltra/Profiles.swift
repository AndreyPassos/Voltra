import Foundation

struct AudioProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var inputUID: String
    var outputUID: String
    var volume: Float?
    var appMix: [String: AppMix]?
    var outputMuted: Bool? = nil
    func withObservedSnapshot(inputUID: String, outputUID: String, volume: Float?, appMix: [String: AppMix], outputMuted: Bool?) -> AudioProfile {
        let sameOutput = self.outputUID == outputUID
        return withSnapshot(inputUID: inputUID, outputUID: outputUID,
                            volume: volume ?? (sameOutput ? self.volume : nil), appMix: appMix,
                            outputMuted: outputMuted ?? (sameOutput ? self.outputMuted : nil))
    }
    func withSnapshot(inputUID: String, outputUID: String, volume: Float?, appMix: [String: AppMix], outputMuted: Bool? = nil) -> AudioProfile {
        AudioProfile(id: id, name: name, inputUID: inputUID, outputUID: outputUID, volume: volume, appMix: appMix, outputMuted: outputMuted)
    }
}
enum ProfileOutputPolicy {
    enum Failure { case volume, mute }
    static func failure(volumeRequested: Bool, volumeAvailable: Bool, muteRequested: Bool, muteAvailable: Bool) -> Failure? {
        if volumeRequested && !volumeAvailable { return .volume }
        if muteRequested && !muteAvailable { return .mute }
        return nil
    }
}
struct ProfileStore {
    let defaults: UserDefaults
    func load() -> [AudioProfile] {
        guard let data = defaults.data(forKey: "profiles") else { return [] }
        return (try? JSONDecoder().decode([AudioProfile].self, from: data)) ?? []
    }
    func createDefaultIfNeeded(name: String, inputUID: String, outputUID: String, volume: Float?, appMix: [String: AppMix], outputMuted: Bool? = nil) -> AudioProfile? {
        if let data = defaults.data(forKey: "profiles") {
            if let existing = try? JSONDecoder().decode([AudioProfile].self, from: data) {
                guard existing.isEmpty else { return nil }
            } else {
                defaults.set(data, forKey: "profiles.corruptBackup")
            }
        }
        let profile = AudioProfile(id: UUID(), name: name, inputUID: inputUID, outputUID: outputUID, volume: volume, appMix: appMix, outputMuted: outputMuted)
        save([profile])
        return profile
    }
    func save(_ profiles: [AudioProfile]) {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "profiles") }
    }
}
