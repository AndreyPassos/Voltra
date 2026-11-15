import Foundation
import Carbon

enum ShortcutKey: String, CaseIterable, Identifiable {
    case m, v, s
    var id: String { rawValue }
    var label: String { "⌃⌥⌘" + rawValue.uppercased() }
    var keyCode: UInt32 {
        switch self { case .m: return UInt32(kVK_ANSI_M); case .v: return UInt32(kVK_ANSI_V); case .s: return UInt32(kVK_ANSI_S) }
    }
}
protocol GlobalShortcutRegistering: AnyObject {
    func register(_ key: ShortcutKey, action: @escaping () -> Void) throws
    func unregister()
}
final class CarbonGlobalShortcut: GlobalShortcutRegistering {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private static let signature: OSType = 0x56544C52
    private static let callback: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard result == noErr, identifier.signature == signature, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
        let instance = Unmanaged<CarbonGlobalShortcut>.fromOpaque(context).takeUnretainedValue()
        guard instance.hotkey != nil, instance.action != nil else { return OSStatus(eventNotHandledErr) }
        DispatchQueue.main.async { instance.action?() }
        return noErr
    }
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { VoltraLanguage.format("O atalho não pôde ser registrado (erro %d); ele pode estar em uso.", status) }
    }
    func register(_ key: ShortcutKey, action: @escaping () -> Void) throws {
        unregister()
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw Failure(status: status) }
        }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(key.keyCode, UInt32(controlKey | optionKey | cmdKey), identifier, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotkey)
        guard status == noErr else {
            if let handler { RemoveEventHandler(handler); self.handler = nil }
            throw Failure(status: status)
        }
        self.action = action
    }
    func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        action = nil
    }
    deinit { unregister(); if let handler { RemoveEventHandler(handler) } }
}
final class GlobalShortcutController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var key: ShortcutKey
    @Published private(set) var message: String?
    private let defaults: UserDefaults
    private let backend: any GlobalShortcutRegistering
    private let action: () -> Void
    init(defaults: UserDefaults = .standard, backend: any GlobalShortcutRegistering = CarbonGlobalShortcut(), action: @escaping () -> Void) {
        self.defaults = defaults; self.backend = backend; self.action = action
        key = ShortcutKey(rawValue: defaults.string(forKey: "shortcutKey") ?? "") ?? .m
        if defaults.bool(forKey: "globalShortcutEnabled") { setEnabled(true) }
    }
    func setEnabled(_ value: Bool) {
        if value {
            do { try backend.register(key, action: action); enabled = true; message = nil }
            catch { enabled = false; message = error.localizedDescription }
        } else { backend.unregister(); enabled = false; message = nil }
        defaults.set(enabled, forKey: "globalShortcutEnabled")
    }
    func setKey(_ newKey: ShortcutKey) {
        guard newKey != key else { return }
        if enabled {
            backend.unregister()
            do { try backend.register(newKey, action: action) }
            catch {
                do { try backend.register(key, action: action) }
                catch { enabled = false; defaults.set(false, forKey: "globalShortcutEnabled") }
                message = VoltraLanguage.format("Não foi possível registrar o novo atalho. %@", error.localizedDescription)
                return
            }
        }
        key = newKey
        defaults.set(newKey.rawValue, forKey: "shortcutKey")
        message = nil
    }
}
