import Foundation
import CoreAudio
import AppKit

struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let input: Bool
    let output: Bool
    let builtIn: Bool
    var transport: UInt32 = 0
}

enum HeadsetPair {
    static func inputUID(for output: AudioDevice, devices: [AudioDevice]) -> String? {
        func bluetooth(_ device: AudioDevice) -> Bool {
            device.transport == kAudioDeviceTransportTypeBluetooth || device.transport == kAudioDeviceTransportTypeBluetoothLE
        }
        guard output.output, bluetooth(output) else { return nil }
        if output.input { return output.uid }
        func identity(_ uid: String) -> String? {
            let lower = uid.lowercased()
            if lower.hasSuffix(":input") { return String(lower.dropLast(6)) }
            if lower.hasSuffix(":output") { return String(lower.dropLast(7)) }
            return nil
        }
        guard let key = identity(output.uid), !key.isEmpty else { return nil }
        let matches = devices.filter { bluetooth($0) && identity($0.uid) == key }
        let inputs = matches.filter(\.input)
        let outputs = matches.filter(\.output)
        guard inputs.count == 1, outputs.count == 1 else { return nil }
        return inputs.first?.uid
    }
}

enum DevicePolicy {
    static func target(devices: [AudioDevice], preferred: String?, automatic: Bool, input: Bool, currentID: AudioObjectID? = nil) -> AudioDevice? {
        guard automatic, let preferred, !preferred.isEmpty else { return nil }
        let capable = devices.filter { input ? $0.input : $0.output }
        return capable.first { $0.uid == preferred } ?? capable.first { $0.builtIn && $0.id == currentID } ?? capable.first { $0.builtIn }
    }
}

struct DevicePreferences: Equatable {
    var inputUID: String
    var outputUID: String
    var automatic: Bool
    static func load(from defaults: UserDefaults) -> Self {
        let previous = defaults.string(forKey: "preferredUID") ?? ""
        return Self(inputUID: defaults.string(forKey: "preferredInputUID") ?? previous, outputUID: defaults.string(forKey: "preferredOutputUID") ?? previous, automatic: defaults.bool(forKey: "automatic"))
    }
    func save(to defaults: UserDefaults) {
        defaults.set(inputUID, forKey: "preferredInputUID")
        defaults.set(outputUID, forKey: "preferredOutputUID")
        defaults.set(automatic, forKey: "automatic")
    }
    func target(devices: [AudioDevice], input: Bool) -> AudioDevice? {
        DevicePolicy.target(devices: devices, preferred: input ? inputUID : outputUID, automatic: automatic, input: input)
    }
}

struct ActiveApp: Identifiable, Equatable {
    let id: String
    let name: String
    let processes: [AudioObjectID]
    var bundleURL: URL? = nil
}
struct AppMix: Codable, Equatable {
    var volume: Float
    var muted: Bool
    var outputUID: String?
    init(volume: Float = 1, muted: Bool = false, outputUID: String? = nil) {
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 1
        self.muted = muted
        self.outputUID = outputUID?.isEmpty == false ? outputUID : nil
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(volume: try values.decodeIfPresent(Float.self, forKey: .volume) ?? 1,
                  muted: try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
                  outputUID: try values.decodeIfPresent(String.self, forKey: .outputUID))
    }
}
enum AppOutputSupport {
    static func isSupported(_ device: AudioDevice) -> Bool {
        device.output && (!device.input || device.transport == kAudioDeviceTransportTypeVirtual)
    }
}
enum AppRoute {
    static func output(for uid: String?, devices: [AudioDevice], defaultID: AudioObjectID) -> AudioDevice? {
        devices.first { $0.output && (uid == nil ? $0.id == defaultID : $0.uid == uid) }
    }
}

@available(macOS 14.2, *)
protocol ManagedAudioSession: AnyObject {
    var diagnostics: (UInt32, Float, Float) { get }
    var cleanupFailed: Bool { get }
    func start(processes: [AudioObjectID], output: AudioDevice) throws
    func stop()
    func setGain(_ gain: Float, muted: Bool)
    func shouldStopForBufferHealth(at time: TimeInterval) -> Bool
}
@available(macOS 14.2, *)
extension ProcessTap: ManagedAudioSession {
    func shouldStopForBufferHealth(at time: TimeInterval) -> Bool { StreamHealth.shouldStop(underruns: underruns, overruns: overruns) }
}
@available(macOS 14.2, *)
extension DuplexProcessTap: ManagedAudioSession {}

struct SessionSignature: Equatable {
    var processes: [AudioObjectID]
    var outputUID: String
    var outputID: AudioObjectID = 0
}
enum SessionAction { case keep, start, stop, wait }
enum SessionPolicy {
    static func action(desired: Bool, candidate: SessionSignature?, current: SessionSignature?, failed: SessionSignature?) -> SessionAction {
        guard desired, let candidate else { return current == nil ? .wait : .stop }
        if current == candidate { return .keep }
        if failed == candidate { return current == nil ? .wait : .stop }
        return .start
    }
}

enum SessionRetryPolicy {
    static func allowed(attempts: Int, desired: Bool) -> Bool { desired && attempts < 2 }
}
struct SessionRetryBudget {
    private var signature: SessionSignature?
    private var attempts = 0
    mutating func consume(for candidate: SessionSignature, desired: Bool) -> Bool {
        guard desired else { return false }
        if signature != candidate { signature = candidate; attempts = 0 }
        guard SessionRetryPolicy.allowed(attempts: attempts, desired: desired) else { return false }
        attempts += 1
        return true
    }
}
enum StreamHealth {
    static func shouldStop(underruns: UInt32, overruns: UInt32) -> Bool { underruns > 1024 || overruns > 1024 }
}
struct StreamWatchdog {
    private var lastCallbacks: UInt32?
    private var lastProgress: TimeInterval = 0
    mutating func poll(callbacks: UInt32, at time: TimeInterval) -> Bool {
        if lastCallbacks == nil || callbacks != lastCallbacks {
            lastCallbacks = callbacks
            lastProgress = time
            return false
        }
        return time - lastProgress >= 6
    }
}
private struct ObservedSystemAudio: Equatable {
    let input: AudioObjectID
    let output: AudioObjectID
    let volume: Float?
    let muted: Bool?
}
final class AudioService: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var defaultInput: AudioObjectID = 0
    @Published var defaultOutput: AudioObjectID = 0
    @Published var volume: Float = 0
    @Published var volumeAvailable = false
    private var volumeElements: [UInt32] = []
    private var channelVolumes: [Float] = []
    private var lastAudibleRatios: [Float] = []
    private var volumeDevice: AudioObjectID = 0
    private var observedAudio: ObservedSystemAudio?
    @Published var muted = false
    @Published var muteAvailable = false
    @Published var error: String? { didSet { stalledWarningOwner = nil; automationErrorKey = nil; automationErrorCode = nil } }
    private var stalledWarningOwner: String?
    private var automationErrorKey: String?
    private var automationErrorCode: OSStatus?
    private func profileError(_ key: String, code: OSStatus? = nil) {
        error = code.map { VoltraLanguage.format(key, $0) } ?? VoltraLanguage.text(key)
        automationErrorKey = key
        automationErrorCode = code
    }
    @Published private(set) var notificationsEnabled: Bool = false
    private var notificationRequest = UUID()
    @Published var profiles: [AudioProfile]
    @Published private(set) var activeProfileID: UUID?
    private var applyingProfile = false
    @Published var rules: [ConnectionRule]
    @Published var launchRules: [AppLaunchRule]
    @Published var scheduledRules: [ScheduledRule]
    @Published private(set) var automationHistory: [AutomationRecord]
    @Published var runningApps: [RunningApp] = []
    @Published var activeApps: [ActiveApp] = []
    @Published var appSettings: [String: AppMix] = [:]
    @Published var controlledApps: Set<String> = []
    private var tapSessions: [String: Any] = [:]
    private var audioWorkers: [String: AudioWorker] = [:]
    private var pendingStarts: [String: (UUID, SessionSignature)] = [:]
    @Published private(set) var startingApps: Set<String> = []
    @Published private(set) var stalledStarts: Set<String> = []
    @Published private(set) var quarantinedApps: Set<String> = []
    @Published private(set) var desiredApps: Set<String> = []
    @Published private(set) var controlPreferences: AppControlPreferences
    private var sessionSignatures: [String: SessionSignature] = [:]
    private var failedSignatures: [String: SessionSignature] = [:]
    private var watchdogs: [String: StreamWatchdog] = [:]
    private var retryBudgets: [String: SessionRetryBudget] = [:]
    @Published var preferredUID: String { didSet { persistPreferences() } }
    @Published var preferredInputUID: String { didSet { persistPreferences() } }
    @Published var automatic: Bool { didSet { persistPreferences() } }
    private let defaults: UserDefaults
    private let allowVirtualDuplex: Bool
    private let deviceVisible: (AudioDevice) -> Bool
    private let sessionDeviceID: (AudioDevice) -> AudioObjectID
    private let virtualCaptureRateOverride: Float64?
    private let duplexCleanupResult: (OSStatus) -> OSStatus
    private let standardCleanupResult: (OSStatus) -> OSStatus
    private let now: () -> Date
    private let notifications: any AudioNotificationManaging
    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var systemListeners: [Listener] = []
    private var outputListeners: [Listener] = []
    private var listenerOutput: AudioObjectID = 0
    private var listenerElements: [UInt32] = []
    private var refreshWork: DispatchWorkItem?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var deferredDevicePolicy = DeferredDevicePolicy()
    private var lastTopology = ""
    private var lastUIDs: Set<String> = []
    private var pendingConnections: Set<String> = []
    private var lastRunningIDs: Set<String>?
    private var pendingLaunches: Set<String> = []
    private var scheduleLastFired: [String: String] = [:]
    private var scheduleQueue = ScheduleQueue()

    init(defaults: UserDefaults = .standard, startTimer: Bool = true, now: @escaping () -> Date = Date.init, notifications: any AudioNotificationManaging = SystemAudioNotifications(), allowVirtualDuplex: Bool = true, duplexCleanupResult: @escaping (OSStatus) -> OSStatus = { $0 }, standardCleanupResult: @escaping (OSStatus) -> OSStatus = { $0 }, deviceVisible: @escaping (AudioDevice) -> Bool = { _ in true }, sessionDeviceID: @escaping (AudioDevice) -> AudioObjectID = { $0.id }, virtualCaptureRateOverride: Float64? = nil) {
        self.defaults = defaults
        self.allowVirtualDuplex = allowVirtualDuplex
        self.duplexCleanupResult = duplexCleanupResult
        self.standardCleanupResult = standardCleanupResult
        self.deviceVisible = deviceVisible
        self.sessionDeviceID = sessionDeviceID
        self.virtualCaptureRateOverride = virtualCaptureRateOverride
        self.now = now
        self.notifications = notifications
        let loadedControl = AppControlPreferences.loadState(from: defaults)
        controlPreferences = loadedControl.preferences
        let loadedProfiles = ProfileStore(defaults: defaults).load()
        profiles = loadedProfiles
        let storedProfileID = defaults.string(forKey: "activeProfileID").flatMap(UUID.init(uuidString:))
        activeProfileID = loadedProfiles.first(where: { $0.id == storedProfileID })?.id ?? loadedProfiles.first?.id
        rules = AutomationStore(defaults: defaults).load()
        launchRules = AppLaunchRuleStore(defaults: defaults).load()
        scheduledRules = ScheduledRuleStore(defaults: defaults).load()
        automationHistory = AutomationHistoryStore(defaults: defaults).load()
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        scheduleLastFired = defaults.dictionary(forKey: "scheduleLastFired") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: "appMix"), let settings = try? JSONDecoder().decode([String: AppMix].self, from: data) { appSettings = settings }
        let preferences = DevicePreferences.load(from: defaults)
        preferredUID = preferences.outputUID
        preferredInputUID = preferences.inputUID
        automatic = preferences.automatic
        refresh()
        if let id = activeProfileID {
            if storedProfileID == id, let profile = profiles.first(where: { $0.id == id }) { _ = applyProfile(profile) }
            else { setActiveProfile(id) }
        }
        if loadedControl.recoveredFromCorruption && error == nil {
            error = VoltraLanguage.text("As preferências de controle por aplicativo estavam inválidas. O controle automático foi desativado; revise as configurações.")
        }
        installSystemListeners()
        schedulePolicy()
        if startTimer { timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() } }
    }
    deinit {
        timer?.invalidate()
        pending?.cancel()
        refreshWork?.cancel()
        removeListeners(&systemListeners)
        removeListeners(&outputListeners)
    }
    private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, element: UInt32, to listeners: inout [Listener]) {
        var property = address(selector, scope, element)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleAudioRefresh() }
        if AudioObjectAddPropertyListenerBlock(object, &property, DispatchQueue.main, block) == noErr {
            listeners.append(Listener(object: object, address: property, block: block))
        }
    }
    private func removeListeners(_ listeners: inout [Listener]) {
        for listener in listeners {
            var property = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &property, DispatchQueue.main, listener.block)
        }
        listeners.removeAll()
    }
    private func installSystemListeners() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: selector, scope: kAudioObjectPropertyScopeGlobal, element: 0, to: &systemListeners)
        }
        if #available(macOS 14.2, *) {
            addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList, scope: kAudioObjectPropertyScopeGlobal, element: 0, to: &systemListeners)
        }
    }
    private func updateOutputListeners() {
        guard listenerOutput != defaultOutput || listenerElements != volumeElements else { return }
        removeListeners(&outputListeners)
        listenerOutput = defaultOutput
        listenerElements = volumeElements
        guard defaultOutput != 0 else { return }
        for element in Set(volumeElements + [0]) {
            addListener(object: defaultOutput, selector: kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element, to: &outputListeners)
        }
        addListener(object: defaultOutput, selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: 0, to: &outputListeners)
    }
    private func scheduleAudioRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
    private func persistPreferences() {
        DevicePreferences(inputUID: preferredInputUID, outputUID: preferredUID, automatic: automatic).save(to: defaults)
        schedulePolicy()
    }
    private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    private func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T {
        var a = address(selector, scope); var value = fallback; var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, UnsafeMutableRawPointer($0)) }
        guard status == noErr else { return fallback }; return value
    }
    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var a = address(selector); var value: CFString?; var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, UnsafeMutableRawPointer($0)) }
        guard status == noErr, let value else { return "" }; return value as String
    }
    private func hasChannels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var a = address(kAudioDevicePropertyStreams, scope); var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }
    private func outputChannelCount(_ id: AudioObjectID) -> UInt32 {
        var a = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, storage) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return min(256, list.reduce(UInt32(0)) { $0 + $1.mNumberChannels })
    }
    private func volumeElementIsSettable(_ id: AudioObjectID, element: UInt32) -> Bool {
        var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }
    private func channelVolume(_ id: AudioObjectID, element: UInt32) -> Float? {
        var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : nil
    }
    private func ids(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(selector); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? result : []
    }
    func refresh() {
        let found = ids(kAudioHardwarePropertyDevices).map { id in
            let transport = scalar(id, kAudioDevicePropertyTransportType, default: UInt32(0))
            return AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName), input: hasChannels(id, kAudioDevicePropertyScopeInput), output: hasChannels(id, kAudioDevicePropertyScopeOutput), builtIn: transport == kAudioDeviceTransportTypeBuiltIn, transport: transport)
        }.filter { !$0.uid.isEmpty && !$0.uid.hasPrefix("com.voltra.aggregate.") && ($0.input || $0.output) && deviceVisible($0) }
        devices = found
        defaultInput = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0))
        defaultOutput = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
        let master = volumeElementIsSettable(defaultOutput, element: 0)
        let count = outputChannelCount(defaultOutput)
        let channels: [UInt32] = count > 0 ? (1...count).filter { volumeElementIsSettable(defaultOutput, element: $0) } : []
        let newElements = VolumePolicy.elements(masterSettable: master, channelElements: channels)
        if volumeDevice != defaultOutput || volumeElements != newElements { lastAudibleRatios = []; volumeDevice = defaultOutput }
        volumeElements = newElements
        channelVolumes = volumeElements.compactMap { channelVolume(defaultOutput, element: $0) }
        volumeAvailable = !volumeElements.isEmpty && channelVolumes.count == volumeElements.count
        if volumeAvailable {
            volume = channelVolumes.max() ?? 0
            if volume > 0 { lastAudibleRatios = channelVolumes.map { $0 / volume } }
        }
        updateOutputListeners()
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var muteSettable: DarwinBoolean = false
        muteAvailable = AudioObjectHasProperty(defaultOutput, &a) && AudioObjectIsPropertySettable(defaultOutput, &a, &muteSettable) == noErr && muteSettable.boolValue
        muted = scalar(defaultOutput, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, default: UInt32(0)) != 0
        if profiles.isEmpty,
           let initial = ProfileStore(defaults: defaults).createDefaultIfNeeded(name: VoltraLanguage.text("Perfil padrão"), inputUID: devices.first(where: { $0.id == defaultInput })?.uid ?? "", outputUID: devices.first(where: { $0.id == defaultOutput })?.uid ?? "", volume: volumeAvailable ? volume : nil, appMix: appSettings, outputMuted: muteAvailable ? muted : nil) {
            profiles = [initial]
            setActiveProfile(initial.id)
        }
        if #available(macOS 14.2, *) {
            var groups: [String: ActiveApp] = [:]
            for object in ids(kAudioHardwarePropertyProcessObjectList) {
                let running: UInt32 = scalar(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))
                guard running != 0 else { continue }
                let pid: pid_t = scalar(object, kAudioProcessPropertyPID, default: pid_t(0))
                guard pid != ProcessInfo.processInfo.processIdentifier, let identity = ApplicationIdentity.resolveProcess(pid) else { continue }
                let key = identity.id
                let processIDs = (groups[key]?.processes ?? []) + [object]
                groups[key] = ActiveApp(id: key, name: identity.name, processes: processIDs.sorted(), bundleURL: identity.bundleURL)
            }
            activeApps = groups.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let wanted = controlPreferences.enabled.union(groups.keys.filter { controlPreferences.shouldControl($0) })
            for id in desiredApps.subtracting(wanted) {
                failedSignatures.removeValue(forKey: id)
                retryBudgets.removeValue(forKey: id)
                teardownApp(id)
            }
            desiredApps = wanted
            for key in Array(desiredApps) {
                if quarantinedApps.contains(key) { continue }
                if let tap = tapSessions[key] as? any ManagedAudioSession, let signature = sessionSignatures[key] {
                    var watchdog = watchdogs[key] ?? StreamWatchdog()
                    if tap.shouldStopForBufferHealth(at: ProcessInfo.processInfo.systemUptime) || watchdog.poll(callbacks: tap.diagnostics.0, at: ProcessInfo.processInfo.systemUptime) {
                        teardownApp(key)
                        recordFailure(key, signature: signature)
                        error = VoltraLanguage.text("O fluxo de áudio parou ou o formato do dispositivo mudou. Tentando recuperar a conexão.")
                    } else { watchdogs[key] = watchdog }
                }
                let app = groups[key]
                let output = AppRoute.output(for: settings(for: key).outputUID, devices: found, defaultID: defaultOutput)
                let candidate = app.flatMap { app in output.map { SessionSignature(processes: app.processes, outputUID: $0.uid, outputID: sessionDeviceID($0)) } }
                if let pending = pendingStarts[key] {
                    if pending.1 == candidate { continue }
                    pendingStarts.removeValue(forKey: key)
                    startingApps.remove(key)
                    stalledStarts.remove(key)
                    clearStalledWarning(for: key)
                }
                if candidate == nil { failedSignatures.removeValue(forKey: key) }
                switch SessionPolicy.action(desired: true, candidate: candidate, current: sessionSignatures[key], failed: failedSignatures[key]) {
                case .keep, .wait: break
                case .stop: teardownApp(key)
                case .start:
                    if let app, let output, let candidate { startSession(app, output: output, signature: candidate) }
                }
            }
        }
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, let identity = ApplicationIdentity.resolve(app), !identity.id.hasPrefix("pid:") else { return nil }
            return RunningApp(id: identity.id, name: identity.name)
        }
        runningApps = Array(Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let runningIDs = Set(runningApps.map(\.id))
        if let previous = lastRunningIDs {
            let launched = runningIDs.subtracting(previous)
            if !launched.isEmpty { pendingLaunches.formUnion(launched); schedulePolicy(applyDevices: false) }
        }
        lastRunningIDs = runningIDs
        let topology = found.map { "\($0.uid):\($0.input):\($0.output)" }.sorted().joined(separator: "|")
        let currentUIDs = Set(found.map(\.uid))
        if let message = NotificationPolicy.message(enabled: notificationsEnabled, previous: lastTopology.isEmpty ? nil : lastUIDs, current: currentUIDs) { notifications.post(message) }
        if !lastTopology.isEmpty && topology != lastTopology {
            pendingConnections.formUnion(currentUIDs.subtracting(lastUIDs))
            schedulePolicy()
        }
        lastUIDs = currentUIDs
        lastTopology = topology
        let observed = ObservedSystemAudio(input: defaultInput, output: defaultOutput, volume: volumeAvailable ? volume : nil, muted: muteAvailable ? muted : nil)
        let changed = observedAudio != nil && observedAudio != observed
        observedAudio = observed
        if changed { saveActiveProfileSnapshot() }
        if scheduleQueue.capture(rules: scheduledRules, date: now(), calendar: .current, lastFired: scheduleLastFired, availableProfiles: Set(profiles.map(\.id))) { schedulePolicy(applyDevices: false) }
    }
    func setPreferredOutput(_ uid: String) {
        preferredUID = uid
        guard let output = devices.first(where: { $0.uid == uid }), let inputUID = HeadsetPair.inputUID(for: output, devices: devices) else { return }
        preferredInputUID = inputUID
    }
    func setNotificationsEnabled(_ enabled: Bool) {
        let request = UUID()
        notificationRequest = request
        guard enabled else {
            notificationsEnabled = false
            defaults.set(false, forKey: "notificationsEnabled")
            return
        }
        notifications.requestPermission { [weak self] granted in
            guard let self, self.notificationRequest == request else { return }
            self.notificationsEnabled = granted
            self.defaults.set(granted, forKey: "notificationsEnabled")
            if !granted { self.error = VoltraLanguage.text("As notificações não foram autorizadas no macOS.") }
        }
    }
    func saveProfile(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = VoltraLanguage.text("Informe um nome para o perfil."); return }
        let profile = AudioProfile(id: UUID(), name: clean, inputUID: devices.first(where: { $0.id == defaultInput })?.uid ?? "", outputUID: devices.first(where: { $0.id == defaultOutput })?.uid ?? "", volume: volumeAvailable ? volume : nil, appMix: appSettings, outputMuted: muteAvailable ? muted : nil)
        profiles.append(profile)
        ProfileStore(defaults: defaults).save(profiles)
        setActiveProfile(profile.id)
    }
    func updateProfile(_ profile: AudioProfile, named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { error = VoltraLanguage.text("Informe um nome para o perfil."); return }
        profiles[index].name = clean
        ProfileStore(defaults: defaults).save(profiles)
    }
    func replaceProfileSnapshot(_ profile: AudioProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }),
              let input = devices.first(where: { $0.id == defaultInput }),
              let output = devices.first(where: { $0.id == defaultOutput }) else { error = VoltraLanguage.text("Os dispositivos padrão não estão disponíveis."); return }
        profiles[index] = profile.withSnapshot(inputUID: input.uid, outputUID: output.uid, volume: volumeAvailable ? volume : nil, appMix: appSettings, outputMuted: muteAvailable ? muted : nil)
        ProfileStore(defaults: defaults).save(profiles)
    }
    private func setActiveProfile(_ id: UUID) {
        activeProfileID = id
        defaults.set(id.uuidString, forKey: "activeProfileID")
    }
    private func saveActiveProfileSnapshot() {
        guard !applyingProfile, let id = activeProfileID, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let old = profiles[index]
        let input = devices.first(where: { $0.id == defaultInput })?.uid ?? old.inputUID
        let output = devices.first(where: { $0.id == defaultOutput })?.uid ?? old.outputUID
        let next = old.withObservedSnapshot(inputUID: input, outputUID: output, volume: volumeAvailable ? volume : nil, appMix: appSettings, outputMuted: muteAvailable ? muted : nil)
        guard next != old else { return }
        profiles[index] = next
        ProfileStore(defaults: defaults).save(profiles)
    }
    func deleteProfile(_ profile: AudioProfile) {
        guard profiles.count > 1 else { error = VoltraLanguage.text("Mantenha pelo menos um perfil."); return }
        if activeProfileID == profile.id {
            guard let replacement = profiles.first(where: { $0.id != profile.id }), applyProfile(replacement) else { return }
        }
        profiles.removeAll { $0.id == profile.id }
        rules.removeAll { $0.profileID == profile.id }
        launchRules.removeAll { $0.profileID == profile.id }
        scheduledRules.removeAll { $0.profileID == profile.id }
        ScheduledRuleStore(defaults: defaults).save(scheduledRules)
        AutomationStore(defaults: defaults).save(rules)
        AppLaunchRuleStore(defaults: defaults).save(launchRules)
        ProfileStore(defaults: defaults).save(profiles)
    }
    @discardableResult func applyProfile(_ profile: AudioProfile) -> Bool {
        guard profiles.contains(where: { $0.id == profile.id }) else { return false }
        applyingProfile = true
        defer { applyingProfile = false }
        guard let input = devices.first(where: { $0.uid == profile.inputUID && $0.input }), let output = devices.first(where: { $0.uid == profile.outputUID && $0.output }) else {
            profileError("Os dispositivos do perfil não estão disponíveis. Nenhuma alteração foi aplicada.")
            return false
        }
        let channelCount = outputChannelCount(output.id)
        let channelElements: [UInt32] = channelCount > 0 ? (1...channelCount).filter { volumeElementIsSettable(output.id, element: $0) } : []
        let elements = VolumePolicy.elements(masterSettable: volumeElementIsSettable(output.id, element: 0), channelElements: channelElements)
        let volumeSupported = !elements.isEmpty && elements.allSatisfy { channelVolume(output.id, element: $0) != nil }
        var muteAddress = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var muteSettable: DarwinBoolean = false
        let muteSupported = AudioObjectHasProperty(output.id, &muteAddress) && AudioObjectIsPropertySettable(output.id, &muteAddress, &muteSettable) == noErr && muteSettable.boolValue
        if let failure = ProfileOutputPolicy.failure(volumeRequested: profile.volume != nil, volumeAvailable: volumeSupported, muteRequested: profile.outputMuted != nil, muteAvailable: muteSupported) {
            profileError(failure == .volume ? "A saída do perfil não suporta controle de volume. Nenhuma alteração foi aplicada." : "A saída do perfil não suporta silêncio. Nenhuma alteração foi aplicada.")
            return false
        }
        guard setDefault(input.id, input: true) else { return false }
        guard setDefault(output.id, input: false) else { profileError("A entrada foi alterada, mas não foi possível alterar a saída."); return false }
        if let volume = profile.volume {
            guard volumeAvailable else { profileError("Os dispositivos foram alterados, mas a saída não oferece controle de volume."); return false }
            guard setVolume(volume) else { return false }
        }
        if let targetMuted = profile.outputMuted {
            guard muteAvailable else { profileError("Os dispositivos foram alterados, mas a saída não oferece controle de silêncio."); return false }
            if muted != targetMuted {
                guard setMute(targetMuted) else { return false }
            }
        }
        let saved = profile.appMix ?? [:]
        appSettings = saved
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "appMix") }
        if #available(macOS 14.2, *) {
            for (id, raw) in tapSessions {
                if let tap = raw as? any ManagedAudioSession { let state = saved[id] ?? AppMix(); tap.setGain(state.volume, muted: state.muted) }
            }
        }
        failedSignatures.removeAll()
        refresh()
        setActiveProfile(profile.id)
        return true
    }
    func addRule(deviceUID: String, profileID: UUID) {
        guard !deviceUID.isEmpty, profiles.contains(where: { $0.id == profileID }) else { return }
        rules.append(ConnectionRule(id: UUID(), deviceUID: deviceUID, profileID: profileID, enabled: true))
        AutomationStore(defaults: defaults).save(rules)
    }
    func toggleRule(_ rule: ConnectionRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].enabled.toggle()
        AutomationStore(defaults: defaults).save(rules)
    }
    func moveRule(_ rule: ConnectionRule, offset: Int) {
        rules = AutomationPolicy.moving(rules, id: rule.id, offset: offset)
        AutomationStore(defaults: defaults).save(rules)
    }
    func deleteRule(_ rule: ConnectionRule) {
        rules.removeAll { $0.id == rule.id }
        AutomationStore(defaults: defaults).save(rules)
    }
    func addLaunchRule(bundleID: String, profileID: UUID) {
        guard !bundleID.isEmpty, profiles.contains(where: { $0.id == profileID }) else { return }
        launchRules.append(AppLaunchRule(id: UUID(), bundleID: bundleID, profileID: profileID, enabled: true))
        AppLaunchRuleStore(defaults: defaults).save(launchRules)
    }
    func toggleLaunchRule(_ rule: AppLaunchRule) {
        guard let index = launchRules.firstIndex(where: { $0.id == rule.id }) else { return }
        launchRules[index].enabled.toggle()
        AppLaunchRuleStore(defaults: defaults).save(launchRules)
    }
    func moveLaunchRule(_ rule: AppLaunchRule, offset: Int) {
        launchRules = AutomationPolicy.moving(launchRules, id: rule.id, offset: offset)
        AppLaunchRuleStore(defaults: defaults).save(launchRules)
    }
    func deleteLaunchRule(_ rule: AppLaunchRule) {
        launchRules.removeAll { $0.id == rule.id }
        AppLaunchRuleStore(defaults: defaults).save(launchRules)
    }
    func addScheduledRule(hour: Int, minute: Int, profileID: UUID) {
        guard (0...23).contains(hour), (0...59).contains(minute), profiles.contains(where: { $0.id == profileID }) else { return }
        scheduledRules.append(ScheduledRule(id: UUID(), hour: hour, minute: minute, profileID: profileID, enabled: true))
        ScheduledRuleStore(defaults: defaults).save(scheduledRules)
    }
    func toggleScheduledRule(_ rule: ScheduledRule) {
        guard let index = scheduledRules.firstIndex(where: { $0.id == rule.id }) else { return }
        scheduledRules[index].enabled.toggle()
        ScheduledRuleStore(defaults: defaults).save(scheduledRules)
    }
    func moveScheduledRule(_ rule: ScheduledRule, offset: Int) {
        scheduledRules = AutomationPolicy.moving(scheduledRules, id: rule.id, offset: offset)
        ScheduledRuleStore(defaults: defaults).save(scheduledRules)
    }
    func deleteScheduledRule(_ rule: ScheduledRule) {
        scheduledRules.removeAll { $0.id == rule.id }
        scheduleLastFired.removeValue(forKey: rule.id.uuidString)
        defaults.set(scheduleLastFired, forKey: "scheduleLastFired")
        ScheduledRuleStore(defaults: defaults).save(scheduledRules)
    }
    private func applyConnectionRules() {
        let connected = pendingConnections.intersection(Set(devices.map(\.uid)))
        let launched = pendingLaunches.intersection(Set(runningApps.map(\.id)))
        pendingConnections.removeAll()
        pendingLaunches.removeAll()
        let available = Set(profiles.map(\.id))
        let deviceProfile = AutomationPolicy.profileToActivate(rules: rules, connected: connected, availableProfiles: available)
        let appProfile = AutomationPolicy.profileForLaunch(rules: launchRules, launched: launched, availableProfiles: available)
        let batch = scheduleQueue.take()
        let validScheduled = batch?.rules.filter { candidate in
            scheduledRules.contains(where: { $0 == candidate && $0.enabled }) && available.contains(candidate.profileID)
        } ?? []
        if let batch {
            for rule in validScheduled { scheduleLastFired[rule.id.uuidString] = batch.day }
            if !validScheduled.isEmpty { defaults.set(scheduleLastFired, forKey: "scheduleLastFired") }
        }
        guard let id = deviceProfile ?? appProfile ?? validScheduled.first?.profileID, let profile = profiles.first(where: { $0.id == id }) else { return }
        let trigger = deviceProfile != nil ? "Dispositivo" : (appProfile != nil ? "Aplicativo" : "Horário")
        error = nil
        let succeeded = applyProfile(profile)
        let event = AutomationRecord(id: UUID(), date: now(), profileName: profile.name, trigger: trigger, succeeded: succeeded, detail: succeeded ? nil : error, detailKey: succeeded ? nil : automationErrorKey, detailCode: succeeded ? nil : automationErrorCode)
        automationHistory = AutomationHistory.newest(automationHistory + [event])
        AutomationHistoryStore(defaults: defaults).save(automationHistory)
    }
    func activeOutputUID(for id: String) -> String? { sessionSignatures[id]?.outputUID }
    func sessionClientRate(for id: String) -> Float64? {
        guard #available(macOS 14.2, *), let tap = tapSessions[id] as? DuplexProcessTap else { return nil }
        return tap.clientSampleRate
    }
    func sessionDiagnostics(for id: String) -> (UInt32, Float, Float)? {
        if #available(macOS 14.2, *), let tap = tapSessions[id] as? any ManagedAudioSession { return tap.diagnostics }
        return nil
    }
    func settings(for id: String) -> AppMix { appSettings[id] ?? AppMix() }
    func setAppMix(_ app: ActiveApp, volume: Float? = nil, muted: Bool? = nil) {
        var state = settings(for: app.id)
        if let volume, volume.isFinite { state.volume = min(1, max(0, volume)) }
        if let muted { state.muted = muted }
        appSettings[app.id] = state
        if let data = try? JSONEncoder().encode(appSettings) { defaults.set(data, forKey: "appMix") }
        saveActiveProfileSnapshot()
        if #available(macOS 14.2, *), let tap = tapSessions[app.id] as? any ManagedAudioSession { tap.setGain(state.volume, muted: state.muted) }
    }
    func setAppOutput(_ app: ActiveApp, uid: String?) {
        var state = settings(for: app.id)
        state.outputUID = uid?.isEmpty == false ? uid : nil
        appSettings[app.id] = state
        if let data = try? JSONEncoder().encode(appSettings) { defaults.set(data, forKey: "appMix") }
        saveActiveProfileSnapshot()
        failedSignatures.removeValue(forKey: app.id)
        if desiredApps.contains(app.id) { refresh() }
    }
    func setAutomaticAppControl(_ enabled: Bool) {
        controlPreferences.automatic = enabled
        controlPreferences.save(to: defaults)
        refresh()
    }
    func startApp(_ app: ActiveApp) {
        controlPreferences.enable(app.id)
        controlPreferences.save(to: defaults)
        desiredApps.insert(app.id)
        retryApp(app)
    }
    func retryApp(_ app: ActiveApp) {
        guard desiredApps.contains(app.id), !quarantinedApps.contains(app.id) else { return }
        failedSignatures.removeValue(forKey: app.id)
        retryBudgets.removeValue(forKey: app.id)
        guard let output = AppRoute.output(for: settings(for: app.id).outputUID, devices: devices, defaultID: defaultOutput) else {
            teardownApp(app.id)
            error = VoltraLanguage.format("A saída escolhida para %@ está indisponível. O controle será retomado quando ela retornar.", app.name)
            return
        }
        startSession(app, output: output, signature: SessionSignature(processes: app.processes, outputUID: output.uid, outputID: sessionDeviceID(output)))
    }
    func reportStalledStart(_ app: ActiveApp) {
        startingApps.remove(app.id)
        stalledStarts.insert(app.id)
        error = VoltraLanguage.format("O macOS ainda não concluiu a inicialização de áudio de %@. Se a espera persistir, reinicie o Voltra.", app.name)
        stalledWarningOwner = app.id
    }
    func clearStalledWarning(for id: String) {
        if stalledWarningOwner == id { error = nil }
    }
    private func quarantineAfterCleanupFailure(_ id: String) {
        quarantinedApps.insert(id)
        pendingStarts.removeValue(forKey: id)
        startingApps.remove(id)
        stalledStarts.remove(id)
        clearStalledWarning(for: id)
        if error == nil { error = VoltraLanguage.text("O macOS não confirmou a liberação de áudio. Reinicie o Voltra se o problema persistir.") }
    }
    @available(macOS 14.2, *)
    private func sessionDisposer(for id: String) -> (any ManagedAudioSession) -> Void {
        { [weak self] tap in
            tap.stop()
            guard tap.cleanupFailed else { return }
            DispatchQueue.main.async { [weak self] in self?.quarantineAfterCleanupFailure(id) }
        }
    }
    private func worker(for id: String) -> AudioWorker {
        if let existing = audioWorkers[id] { return existing }
        let worker = AudioWorker()
        audioWorkers[id] = worker
        return worker
    }
    private func startSession(_ app: ActiveApp, output: AudioDevice, signature: SessionSignature) {
        guard #available(macOS 14.2, *) else { error = VoltraLanguage.text("Requer macOS 14.2 ou posterior."); return }
        guard !quarantinedApps.contains(app.id) else { return }
        teardownApp(app.id)
        let worker = worker(for: app.id)
        let token = UUID()
        pendingStarts[app.id] = (token, signature)
        startingApps.insert(app.id)
        let initialSettings = settings(for: app.id)
        let useVirtualDuplex = allowVirtualDuplex && output.input && output.transport == kAudioDeviceTransportTypeVirtual
        let cleanupResult = duplexCleanupResult
        let captureRateOverride = virtualCaptureRateOverride
        let standardResult = standardCleanupResult
        let dispose = sessionDisposer(for: app.id)
        worker.run({
            let tap: any ManagedAudioSession = useVirtualDuplex ? DuplexProcessTap(cleanupResult: cleanupResult, experimentalCaptureRate: captureRateOverride) : ProcessTap(cleanupResult: standardResult)
            tap.setGain(initialSettings.volume, muted: initialSettings.muted)
            do { try tap.start(processes: app.processes, output: output) }
            catch {
                if tap.cleanupFailed { dispose(tap) }
                throw error
            }
            return tap
        }, shouldStart: { [weak self] in
            guard let self else { return false }
            return self.pendingStarts[app.id]?.0 == token && self.desiredApps.contains(app.id) && !self.quarantinedApps.contains(app.id)
        }, discard: dispose, timeout: 15, onTimeout: { [weak self] in
            guard let self, self.pendingStarts[app.id]?.0 == token, self.desiredApps.contains(app.id) else { return }
            self.reportStalledStart(app)
        }) { [weak self] result in
            guard let self, self.pendingStarts[app.id]?.0 == token, self.desiredApps.contains(app.id) else { return false }
            self.pendingStarts.removeValue(forKey: app.id)
            self.startingApps.remove(app.id)
            self.stalledStarts.remove(app.id)
            self.clearStalledWarning(for: app.id)
            switch result {
            case let .failure(failure):
                self.recordFailure(app.id, signature: signature)
                self.error = VoltraLanguage.format("Não foi possível controlar %@: %@", app.name, failure.localizedDescription)
            case let .success(tap):
                let settings = self.settings(for: app.id)
                tap.setGain(settings.volume, muted: settings.muted)
                self.tapSessions[app.id] = tap
                self.sessionSignatures[app.id] = signature
                self.failedSignatures.removeValue(forKey: app.id)
                self.controlledApps.insert(app.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak tap] in
                    guard let self, let tap, let current = self.tapSessions[app.id] as? any ManagedAudioSession, current === tap, !tap.shouldStopForBufferHealth(at: ProcessInfo.processInfo.systemUptime), tap.diagnostics.0 > 0 else { return }
                    self.retryBudgets.removeValue(forKey: app.id)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak tap] in
                    guard let self, let tap, let current = self.tapSessions[app.id] as? any ManagedAudioSession, current === tap else { return }
                    if tap.diagnostics.0 == 0 {
                        self.teardownApp(app.id)
                        self.recordFailure(app.id, signature: signature)
                        self.error = VoltraLanguage.format("O fluxo de áudio de %@ não iniciou. Verifique a permissão de áudio do sistema e a compatibilidade da saída.", app.name)
                    }
                }
            }
            return true
        }
    }
    private func recordFailure(_ id: String, signature: SessionSignature) {
        failedSignatures[id] = signature
        var budget = retryBudgets[id] ?? SessionRetryBudget()
        let allowed = budget.consume(for: signature, desired: desiredApps.contains(id))
        retryBudgets[id] = budget
        guard allowed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.desiredApps.contains(id), self.failedSignatures[id] == signature else { return }
            self.failedSignatures.removeValue(forKey: id)
            self.refresh()
        }
    }
    private func teardownApp(_ id: String) {
        pendingStarts.removeValue(forKey: id)
        startingApps.remove(id)
        stalledStarts.remove(id)
        clearStalledWarning(for: id)
        if #available(macOS 14.2, *), let tap = tapSessions.removeValue(forKey: id) as? any ManagedAudioSession {
            let dispose = sessionDisposer(for: id)
            worker(for: id).dispose { dispose(tap) }
        }
        sessionSignatures.removeValue(forKey: id)
        watchdogs.removeValue(forKey: id)
        controlledApps.remove(id)
    }
    func stopApp(_ id: String) {
        controlPreferences.disable(id)
        controlPreferences.save(to: defaults)
        desiredApps.remove(id)
        failedSignatures.removeValue(forKey: id)
        retryBudgets.removeValue(forKey: id)
        teardownApp(id)
    }
    @discardableResult func setDefault(_ id: AudioObjectID, input: Bool) -> Bool {
        var a = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice); var value = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        if status != noErr { profileError("Não foi possível alterar o dispositivo (erro %d).", code: status) }; refresh(); if status == noErr { saveActiveProfileSnapshot() }; return status == noErr
    }
    @discardableResult func setVolume(_ value: Float) -> Bool {
        guard volumeAvailable, volumeElements.count == channelVolumes.count else { return false }
        let targets = VolumePolicy.scaled(channelVolumes, target: value, fallback: lastAudibleRatios)
        var failure: OSStatus = noErr
        for (element, target) in zip(volumeElements, targets) {
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
            var v = target
            let status = AudioObjectSetPropertyData(defaultOutput, &a, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
            if status != noErr { failure = status }
        }
        if failure != noErr { profileError("Não foi possível alterar todos os canais (erro %d).", code: failure) }
        refresh()
        if failure == noErr { saveActiveProfileSnapshot() }
        return failure == noErr
    }
    @discardableResult func setMute(_ target: Bool) -> Bool {
        var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput); var v: UInt32 = target ? 1 : 0
        let status = AudioObjectSetPropertyData(defaultOutput, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        if status != noErr { profileError("Não foi possível alterar o silêncio (erro %d).", code: status) }
        refresh()
        return status == noErr
    }
    func toggleMute() { _ = setMute(!muted) }
    func useBoth(_ device: AudioDevice) {
        guard device.input && device.output else { return }
        preferredInputUID = device.uid
        preferredUID = device.uid
        guard setDefault(device.id, input: true) else { return }
        if !setDefault(device.id, input: false) { error = VoltraLanguage.text("A entrada foi alterada, mas não foi possível alterar a saída.") }
    }
    func schedulePolicy(applyDevices: Bool = true) {
        deferredDevicePolicy.enqueue(needsDevicePolicy: applyDevices)
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.deferredDevicePolicy.take() { self.applyPolicy() }
            self.applyConnectionRules()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }
    func applyPolicy() {
        guard automatic else { return }
        if let d = DevicePolicy.target(devices: devices, preferred: preferredInputUID, automatic: automatic, input: true, currentID: defaultInput), d.id != defaultInput { setDefault(d.id, input: true) }
        if let d = DevicePolicy.target(devices: devices, preferred: preferredUID, automatic: automatic, input: false, currentID: defaultOutput), d.id != defaultOutput { setDefault(d.id, input: false) }
    }
}
