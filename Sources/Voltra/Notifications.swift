import Foundation
import UserNotifications

enum NotificationPolicy {
    static func message(enabled: Bool, previous: Set<String>?, current: Set<String>) -> String? {
        guard enabled, let previous, previous != current else { return nil }
        let added = !current.subtracting(previous).isEmpty
        let removed = !previous.subtracting(current).isEmpty
        if added && removed { return VoltraLanguage.text("Dispositivos de áudio alterados.") }
        return added ? VoltraLanguage.text("Dispositivo de áudio conectado.") : VoltraLanguage.text("Dispositivo de áudio desconectado.")
    }
}
protocol AudioNotificationManaging {
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    func post(_ message: String)
}
struct SystemAudioNotifications: AudioNotificationManaging {
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }
    func post(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Voltra"
        content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
