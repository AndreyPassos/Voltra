import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "Voltra", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

@main struct VoltraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("languagePreference") private var languagePreference = "system"
    @StateObject private var audio: AudioService
    @StateObject private var shortcut: GlobalShortcutController
    init() {
        let service = AudioService()
        _audio = StateObject(wrappedValue: service)
        _shortcut = StateObject(wrappedValue: GlobalShortcutController(action: { [weak service] in
            guard let service else { return }
            if service.muteAvailable { service.toggleMute() } else { service.error = VoltraLanguage.text("A saída atual não oferece controle de silêncio.") }
        }))
    }
    var body: some Scene {
        WindowGroup("Voltra", id: "main") { ContentView().environmentObject(audio).environmentObject(shortcut).frame(minWidth: 880, minHeight: 600).preferredColorScheme(.dark) }
            .commands {
                CommandMenu(VoltraLanguage.text("Áudio")) {
                    Button(VoltraLanguage.text(audio.muted ? "Reativar saída" : "Silenciar saída")) { audio.toggleMute() }
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                        .disabled(!audio.muteAvailable)
                }
            }
        MenuBarExtra { CompactView().environmentObject(audio).frame(width: 340).preferredColorScheme(.dark) } label: { MenuBarMark().accessibilityLabel("Voltra") }.menuBarExtraStyle(.window)
    }
}

let navy = Color(red: 0.035, green: 0.055, blue: 0.12)
let accent = Color(red: 0.23, green: 0.51, blue: 0.96)
let brandGradient = LinearGradient(colors: [.cyan, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
struct BrandMark: View {
    var size: CGFloat = 48
    var body: some View {
        Image(systemName: "waveform").font(.system(size: size * 23 / 48, weight: .bold))
            .foregroundStyle(brandGradient).frame(width: size, height: size)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: size / 4))
            .overlay(RoundedRectangle(cornerRadius: size / 4).stroke(brandGradient, lineWidth: size / 40))
            .accessibilityHidden(true)
    }
}
struct CaffeeeSignature: View {
    var body: some View {
        HStack(spacing: 8) {
            if let url = Bundle.main.url(forResource: "CaffeeeLabs", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 32, height: 32)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            Text("by CaffeeeLabs").font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel("by CaffeeeLabs")
    }
}
struct MenuBarMark: View {
    var body: some View { Image(systemName: "waveform") }
}
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.07))) }
}
struct ContentView: View {
    @EnvironmentObject var audio: AudioService
    @AppStorage("onboardingDone") var onboardingDone = false
    @AppStorage("languagePreference") var languagePreference = "system"
    @State private var selected = "Mixer"
    let sections: [(String,String)] = [("Mixer","slider.horizontal.3"),("Devices","headphones"),("Profiles","person.crop.square"),("Automations","bolt"),("Settings","gearshape")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) { BrandMark(); VStack(alignment: .leading, spacing: 3) { Text("Voltra").font(.title2.bold()); Text("Your Mac. Your Sound.").font(.caption2).foregroundStyle(.secondary) } }.padding(.bottom, 32)
                ForEach(sections, id: \.0) { item in Button { selected = item.0 } label: { Label(LocalizedStringKey(item.0), systemImage: item.1).frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle()).background(LinearGradient(colors: selected == item.0 ? [accent.opacity(0.85), Color.purple.opacity(0.70)] : [.clear, .clear], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain) }
                Spacer(); CaffeeeSignature()
            }.padding(24).frame(width: 215).background(Color.black.opacity(0.18))
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                Text(LocalizedStringKey(selected)).font(.system(size: 34, weight: .bold)); Text(LocalizedStringKey(subtitle)).foregroundStyle(.secondary)
                if let error = audio.error { Text(error).foregroundStyle(.orange); Button("Dispensar") { audio.error = nil } }
                switch selected {
                case "Mixer": MixerView()
                case "Devices": DevicesView()
                case "Profiles": ProfilesView()
                case "Automations": AutomationsView()
                default: SettingsView()
                }
            }.padding(36).frame(maxWidth: 900, alignment: .leading) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(LinearGradient(colors: [navy, Color(red: 0.075, green: 0.065, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.locale, Locale(identifier: VoltraLanguage.resolve(languagePreference)))
        .sheet(isPresented: Binding(get: { !onboardingDone }, set: { if !$0 { onboardingDone = true } })) { OnboardingView().environment(\.locale, Locale(identifier: VoltraLanguage.resolve(languagePreference))) }
    }
    var subtitle: String { switch selected { case "Mixer": return "Seu som em um só lugar."; case "Devices": return "Escolha sua entrada e saída."; case "Settings": return "Preferências do Voltra."; default: return "Controle pensado para sua rotina." } }
}
struct VolumeView: View {
    @EnvironmentObject var audio: AudioService
    var body: some View { VStack(alignment: .leading, spacing: 14) {
        HStack { Label("Volume de saída", systemImage: "speaker.wave.2.fill").font(.headline); Spacer(); Text(audio.volumeAvailable ? "\(Int((audio.volume * 100).rounded()))%" : VoltraLanguage.text("Indisponível")).foregroundStyle(.secondary) }
        HStack { Button(action: audio.toggleMute) { Image(systemName: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.accessibilityLabel(audio.muted ? "Reativar saída" : "Silenciar saída").help(Text(LocalizedStringKey(audio.muted ? "Reativar saída" : "Silenciar saída"))).disabled(!audio.muteAvailable); Slider(value: Binding(get: { Double(audio.volume) }, set: { audio.setVolume(Float($0)) }), in: 0...1).accessibilityLabel("Volume de saída").disabled(!audio.volumeAvailable).tint(accent) }
        if !audio.volumeAvailable { Text("O dispositivo atual não oferece controle de volume ao macOS.").font(.caption).foregroundStyle(.secondary) }
    } }
}
struct ProfileSelector: View {
    @EnvironmentObject var audio: AudioService
    var body: some View {
        Picker("Perfil ativo", selection: Binding(get: { audio.activeProfileID?.uuidString ?? "" }, set: { value in
            if let profile = audio.profiles.first(where: { $0.id.uuidString == value }) { _ = audio.applyProfile(profile) }
        })) {
            ForEach(audio.profiles) { profile in Text(profile.name).tag(profile.id.uuidString) }
        }.frame(maxWidth: 340)
    }
}
struct ConfirmDeleteButton: View {
    let label: String
    let detail: LocalizedStringKey
    let action: () -> Void
    @State private var confirming = false
    var body: some View {
        Button(role: .destructive) { confirming = true } label: { Image(systemName: "trash") }
            .help("Excluir").accessibilityLabel(Text(LocalizedStringKey(label)))
            .alert("Confirmar exclusão?", isPresented: $confirming) {
                Button("Cancelar", role: .cancel) { }
                Button("Excluir", role: .destructive, action: action)
            } message: { Text(detail) }
    }
}
struct MixerView: View {
    @EnvironmentObject var audio: AudioService
    var body: some View { Panel { HStack { ProfileSelector(); Spacer() } }; Panel { VolumeView() }; HStack(alignment: .top, spacing: 14) { Panel { DevicePicker(input: false) }; Panel { DevicePicker(input: true) } }; Panel { AppsView() } }
}
struct AppsView: View {
    var compact = false
    @EnvironmentObject var audio: AudioService
    var body: some View { VStack(alignment: .leading, spacing: 12) {
        Label("Aplicativos com áudio ativo", systemImage: "waveform").font(.headline)
        if audio.activeApps.isEmpty { Text("Nenhum aplicativo detectado com áudio ativo.").foregroundStyle(.secondary) }
        ForEach(audio.activeApps) { app in
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    if let url = app.bundleURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                    } else { Image(systemName: "app.fill").frame(width: 28, height: 28) }
                    Text(app.name)
                    Spacer()
                    if audio.quarantinedApps.contains(app.id) {
                        Text("Reinicie o Voltra para retomar o controle.").font(.caption).foregroundStyle(.orange)
                    } else if audio.desiredApps.contains(app.id) {
                        if audio.passthroughApps.contains(app.id) {
                            Text("Chamada: áudio direto").font(.caption).foregroundStyle(.secondary)
                                .help("Em 100%, sem silêncio e na saída escolhida, a chamada usa a reprodução nativa para evitar atenuação. Outros volumes usam o mixer.")
                        } else if audio.startingApps.contains(app.id) {
                            Text("Iniciando áudio…").font(.caption).foregroundStyle(.secondary)
                        } else if audio.stalledStarts.contains(app.id) {
                            Text("Aguardando o macOS iniciar o áudio…").font(.caption).foregroundStyle(.secondary)
                        } else if !audio.controlledApps.contains(app.id) {
                            Text("Aguardando áudio ou saída").font(.caption).foregroundStyle(.secondary)
                            Button("Tentar novamente") { audio.retryApp(app) }
                        }
                        if !audio.controlPreferences.automatic {
                            Button("Desativar") { audio.stopApp(app.id) }
                        }
                    } else if !audio.controlPreferences.automatic {
                        Button("Ativar controle") { audio.startApp(app) }
                    }
                }
                if !compact { Picker("Saída", selection: Binding(get: { audio.settings(for: app.id).outputUID ?? "" }, set: { audio.setAppOutput(app, uid: $0) })) {
                    Text("Padrão do sistema").tag("")
                    ForEach(audio.devices.filter { $0.output }) { device in
                        Text(!AppOutputSupport.isSupported(device) ? String(format: VoltraLanguage.text("%@ — incompatível"), device.name) : device.name)
                            .tag(device.uid).disabled(!AppOutputSupport.isSupported(device))
                    }
                    if let uid = audio.settings(for: app.id).outputUID, !audio.devices.contains(where: { $0.output && $0.uid == uid }) { Text("Saída desconectada").tag(uid) }
                } }
                if audio.controlledApps.contains(app.id) || audio.passthroughApps.contains(app.id) {
                    HStack {
                        Button { audio.setAppMix(app, muted: !audio.settings(for: app.id).muted) } label: { Image(systemName: audio.settings(for: app.id).muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.accessibilityLabel(Text(VoltraLanguage.format(audio.settings(for: app.id).muted ? "Reativar áudio de %@" : "Silenciar %@", app.name))).help(Text(LocalizedStringKey(audio.settings(for: app.id).muted ? "Reativar áudio" : "Silenciar áudio")))
                        Slider(value: Binding(get: { Double(audio.settings(for: app.id).volume) }, set: { audio.setAppMix(app, volume: Float($0)) }), in: 0...1).accessibilityLabel("Volume de \(app.name)").tint(accent)
                        Text("\(Int((audio.settings(for: app.id).volume * 100).rounded()))%").frame(width: 42)
                    }
                }
                if app.inputActive && audio.desiredApps.contains(app.id) && !audio.passthroughApps.contains(app.id) {
                    Text("O macOS pode reduzir este áudio durante o uso do microfone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
        }
        if !compact { Text("O controle solicita acesso ao áudio do sistema. Após mudança de saída ou processo, o Voltra tenta retomá-lo.").font(.caption).foregroundStyle(.secondary) }
    } }
}
struct DevicePicker: View {
    @EnvironmentObject var audio: AudioService
    let input: Bool
    var body: some View { HStack { Label(LocalizedStringKey(input ? "Entrada" : "Saída"), systemImage: input ? "mic.fill" : "speaker.wave.2.fill"); Spacer(); Picker("", selection: Binding(get: { input ? audio.defaultInput : audio.defaultOutput }, set: { audio.setDefault($0, input: input) })) { ForEach(audio.devices.filter { input ? $0.input : $0.output }) { Text($0.name).tag($0.id) } }.labelsHidden().frame(maxWidth: 250) } }
}
struct PreferredPicker: View {
    @EnvironmentObject var audio: AudioService
    let input: Bool
    var body: some View {
        let selection = input ? $audio.preferredInputUID : Binding(get: { audio.preferredUID }, set: { audio.setPreferredOutput($0) })
        let devices = audio.devices.filter { input ? $0.input : $0.output }
        return Picker(LocalizedStringKey(input ? "Entrada preferida" : "Saída preferida"), selection: selection) {
            Text("Nenhum").tag("")
            ForEach(devices) { Text($0.name).tag($0.uid) }
            if !selection.wrappedValue.isEmpty && !devices.contains(where: { $0.uid == selection.wrappedValue }) {
                Text("Preferido desconectado").tag(selection.wrappedValue)
            }
        }
    }
}
struct DeviceList: View {
    @EnvironmentObject var audio: AudioService
    let input: Bool
    var body: some View {
        let devices = audio.devices.filter { input ? $0.input : $0.output }
        let selectedID = input ? audio.defaultInput : audio.defaultOutput
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Label(LocalizedStringKey(input ? "Entradas" : "Saídas"), systemImage: input ? "mic.fill" : "headphones")
                    .font(.headline).foregroundStyle(accent)
                Text(LocalizedStringKey(input ? "Escolha o microfone padrão." : "Escolha onde o som será reproduzido."))
                    .font(.caption).foregroundStyle(.secondary)
                if devices.isEmpty { Text("Nenhum dispositivo disponível.").foregroundStyle(.secondary) }
                ForEach(devices) { device in
                    let selected = device.id == selectedID
                    Button { _ = audio.setDefault(device.id, input: input) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? accent : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name).lineLimit(2).multilineTextAlignment(.leading)
                                Text(LocalizedStringKey(selected ? "Padrão" : (device.builtIn ? "Interno" : "Disponível")))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(selected ? accent.opacity(0.16) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? accent.opacity(0.8) : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(VoltraLanguage.format("%@ %@, %@", VoltraLanguage.text(input ? "Entrada" : "Saída"), device.name, VoltraLanguage.text(selected ? "padrão" : "selecionar como padrão"))))
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
struct DevicesView: View {
    @EnvironmentObject var audio: AudioService
    var body: some View { HStack(alignment: .top, spacing: 14) { DeviceList(input: false); DeviceList(input: true) }; Panel { VStack(alignment: .leading, spacing: 14) {
        Text("Headset preferido").font(.headline)
        PreferredPicker(input: false)
        PreferredPicker(input: true)
        Toggle("Alternar automaticamente e restaurar ao reconectar", isOn: $audio.automatic)
        Text("Ao escolher um headset Bluetooth identificado sem ambiguidade, sua entrada correspondente também é selecionada. Quando indisponível, o Voltra tenta usar os dispositivos internos. A seleção manual pode ser substituída na próxima mudança de conexão.").font(.caption).foregroundStyle(.secondary)
        if let device = audio.devices.first(where: { $0.uid == audio.preferredUID && $0.input && $0.output }) {
            Button("Usar dispositivo preferido como entrada e saída") { audio.useBoth(device) }
        }
    } } }
}
struct ProfilesView: View {
    @EnvironmentObject var audio: AudioService
    @State private var name = ""
    var body: some View {
        Panel { VStack(alignment: .leading, spacing: 12) {
            Text("Salvar configuração atual").font(.headline)
            Text("Guarda entrada, saída, volume geral e ajustes de aplicativos.").font(.caption).foregroundStyle(.secondary)
            HStack { TextField("Nome do perfil", text: $name); Button("Salvar") { audio.saveProfile(named: name); if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "" } } }
        } }
        Panel { VStack(alignment: .leading, spacing: 12) {
            Text("Seus perfis").font(.headline)
            if audio.profiles.isEmpty { Text("Nenhum perfil salvo.").foregroundStyle(.secondary) }
            ForEach(audio.profiles) { profile in
                ProfileRow(profile: profile)
            }
        } }
    }
}
struct ProfileRow: View {
    @EnvironmentObject var audio: AudioService
    let profile: AudioProfile
    @State private var editing = false
    @State private var name = ""
    private func deviceName(_ uid: String) -> String {
        audio.devices.first(where: { $0.uid == uid })?.name ?? VoltraLanguage.text("Dispositivo indisponível")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(brandGradient).font(.title2)
                    .frame(width: 40, height: 40)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                if editing {
                    TextField("Nome do perfil", text: $name)
                    Button("Salvar") { audio.updateProfile(profile, named: name); if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { editing = false } }
                    Button("Cancelar") { editing = false }
                } else {
                    Text(profile.name).font(.headline)
                    if audio.activeProfileID == profile.id { Text("Ativo").font(.caption).foregroundStyle(accent) }
                    Spacer()
                    Button { name = profile.name; editing = true } label: { Image(systemName: "pencil") }
                        .help("Renomear perfil").accessibilityLabel("Renomear perfil \(profile.name)")
                    ConfirmDeleteButton(label: "Excluir perfil", detail: "As automações associadas também serão excluídas.") { audio.deleteProfile(profile) }
                        .disabled(audio.profiles.count <= 1)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                Label(deviceName(profile.outputUID), systemImage: "headphones")
                Label(deviceName(profile.inputUID), systemImage: "mic")
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                if let volume = profile.volume { Text("Volume: \(Int((volume * 100).rounded()))%") }
                Text("Aplicativos: \(profile.appMix?.count ?? 0)")
                Spacer()
                Button("Aplicar") { audio.applyProfile(profile) }.buttonStyle(.borderedProminent).tint(accent).disabled(audio.activeProfileID == profile.id)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07)))
    }
}
struct AutomationsView: View {
    @EnvironmentObject var audio: AudioService
    @State private var deviceUID = ""
    @State private var profileID = ""
    @State private var launchBundleID = ""
    @State private var launchProfileID = ""
    @State private var scheduledTime = Date()
    @State private var scheduledProfileID = ""
    var body: some View {
        Panel { VStack(alignment: .leading, spacing: 12) {
            Text("Ao conectar um dispositivo").font(.headline)
            Text("As regras seguem a ordem exibida. A primeira regra válida tem prioridade sobre a troca automática de dispositivos.").font(.caption).foregroundStyle(.secondary)
            Picker("Dispositivo", selection: $deviceUID) { Text("Selecione").tag(""); ForEach(audio.devices) { Text($0.name).tag($0.uid) } }
            Picker("Perfil", selection: $profileID) { Text("Selecione").tag(""); ForEach(audio.profiles) { Text($0.name).tag($0.id.uuidString) } }
            Button("Criar regra") { if let id = UUID(uuidString: profileID) { audio.addRule(deviceUID: deviceUID, profileID: id) } }.disabled(deviceUID.isEmpty || UUID(uuidString: profileID) == nil)
        } }
        Panel { VStack(alignment: .leading, spacing: 12) {
            Text("Regras de conexão").font(.headline)
            if audio.rules.isEmpty { Text("Nenhuma regra criada.").foregroundStyle(.secondary) }
            ForEach(audio.rules) { rule in
                HStack {
                    VStack(alignment: .leading) { Text(audio.devices.first(where: { $0.uid == rule.deviceUID })?.name ?? VoltraLanguage.text("Dispositivo desconectado")); Text(audio.profiles.first(where: { $0.id == rule.profileID })?.name ?? VoltraLanguage.text("Perfil indisponível")).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button { audio.moveRule(rule, offset: -1) } label: { Image(systemName: "arrow.up") }.help("Aumentar prioridade").accessibilityLabel("Aumentar prioridade"); Button { audio.moveRule(rule, offset: 1) } label: { Image(systemName: "arrow.down") }.help("Reduzir prioridade").accessibilityLabel("Reduzir prioridade"); Toggle("Ativa", isOn: Binding(get: { rule.enabled }, set: { _ in audio.toggleRule(rule) })).labelsHidden(); ConfirmDeleteButton(label: "Excluir regra", detail: "Esta ação não pode ser desfeita.") { audio.deleteRule(rule) }
                }
            }
        } }
        Panel { VStack(alignment: .leading, spacing: 12) {
            Text("Ao abrir um aplicativo").font(.headline)
            Text("Escolha um aplicativo aberto. Regras de conexão têm prioridade quando eventos ocorrem juntos.").font(.caption).foregroundStyle(.secondary)
            Picker("Aplicativo", selection: $launchBundleID) { Text("Selecione").tag(""); ForEach(audio.runningApps) { Text($0.name).tag($0.id) } }
            Picker("Perfil", selection: $launchProfileID) { Text("Selecione").tag(""); ForEach(audio.profiles) { Text($0.name).tag($0.id.uuidString) } }
            Button("Criar regra de aplicativo") { if let id = UUID(uuidString: launchProfileID) { audio.addLaunchRule(bundleID: launchBundleID, profileID: id) } }.disabled(launchBundleID.isEmpty || UUID(uuidString: launchProfileID) == nil)
            ForEach(audio.launchRules) { rule in
                HStack {
                    VStack(alignment: .leading) { Text(audio.runningApps.first(where: { $0.id == rule.bundleID })?.name ?? rule.bundleID); Text(audio.profiles.first(where: { $0.id == rule.profileID })?.name ?? VoltraLanguage.text("Perfil indisponível")).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button { audio.moveLaunchRule(rule, offset: -1) } label: { Image(systemName: "arrow.up") }.help("Aumentar prioridade").accessibilityLabel("Aumentar prioridade"); Button { audio.moveLaunchRule(rule, offset: 1) } label: { Image(systemName: "arrow.down") }.help("Reduzir prioridade").accessibilityLabel("Reduzir prioridade"); Toggle("Ativa", isOn: Binding(get: { rule.enabled }, set: { _ in audio.toggleLaunchRule(rule) })).labelsHidden()
                    ConfirmDeleteButton(label: "Excluir regra", detail: "Esta ação não pode ser desfeita.") { audio.deleteLaunchRule(rule) }
                }
            }
        } }

        Panel { VStack(alignment: .leading, spacing: 12) {
            Text("Em um horário diário").font(.headline)
            Text("Mantenha o Voltra aberto. Após repouso, a regra mais recente é retomada. Dispositivo e aplicativo têm prioridade em eventos simultâneos.").font(.caption).foregroundStyle(.secondary)
            DatePicker("Horário", selection: $scheduledTime, displayedComponents: .hourAndMinute)
            Picker("Perfil", selection: $scheduledProfileID) { Text("Selecione").tag(""); ForEach(audio.profiles) { Text($0.name).tag($0.id.uuidString) } }
            Button("Criar regra de horário") {
                if let id = UUID(uuidString: scheduledProfileID) {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
                    if let hour = parts.hour, let minute = parts.minute { audio.addScheduledRule(hour: hour, minute: minute, profileID: id) }
                }
            }.disabled(UUID(uuidString: scheduledProfileID) == nil)
            ForEach(audio.scheduledRules) { rule in
                HStack {
                    Text(String(format: "%02d:%02d", rule.hour, rule.minute))
                    Text(audio.profiles.first(where: { $0.id == rule.profileID })?.name ?? VoltraLanguage.text("Perfil indisponível")).foregroundStyle(.secondary)
                    Spacer(); Button { audio.moveScheduledRule(rule, offset: -1) } label: { Image(systemName: "arrow.up") }.help("Aumentar prioridade").accessibilityLabel("Aumentar prioridade"); Button { audio.moveScheduledRule(rule, offset: 1) } label: { Image(systemName: "arrow.down") }.help("Reduzir prioridade").accessibilityLabel("Reduzir prioridade"); Toggle("Ativa", isOn: Binding(get: { rule.enabled }, set: { _ in audio.toggleScheduledRule(rule) })).labelsHidden()
                    ConfirmDeleteButton(label: "Excluir regra", detail: "Esta ação não pode ser desfeita.") { audio.deleteScheduledRule(rule) }
                }
            }
        } }

        Panel { VStack(alignment: .leading, spacing: 12) {
            Text("Atividade recente").font(.headline)
            if audio.automationHistory.isEmpty { Text("Nenhuma automação executada.").foregroundStyle(.secondary) }
            ForEach(audio.automationHistory.prefix(20)) { record in
                HStack {
                    Image(systemName: record.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(record.succeeded ? .green : .orange)
                    VStack(alignment: .leading) { Text(record.profileName); Text(VoltraLanguage.text(record.trigger) + VoltraLanguage.text(record.succeeded ? " · Aplicado" : " · Não aplicado por completo")).font(.caption).foregroundStyle(.secondary); if let detail = record.displayDetail(localize: VoltraLanguage.text) { Text(detail).font(.caption).foregroundStyle(.orange) } }
                    Spacer(); Text(record.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
        } }

    }
}
struct SettingsView: View {
    @AppStorage("languagePreference") var languagePreference = "system"
    @EnvironmentObject var audio: AudioService
    @EnvironmentObject var shortcut: GlobalShortcutController
    @StateObject private var login = LoginItemController()
    var body: some View { Panel { VStack(alignment: .leading, spacing: 14) {
        Picker("Idioma", selection: $languagePreference) {
            Text("Idioma do sistema").tag("system")
            Text("Português").tag("pt")
            Text("English").tag("en")
        }
        Toggle("Controlar automaticamente aplicativos com áudio", isOn: Binding(get: { audio.controlPreferences.automatic }, set: { audio.setAutomaticAppControl($0) }))
        Text(LocalizedStringKey(audio.controlPreferences.automatic ? "O Voltra controla automaticamente todos os aplicativos com áudio. O macOS pode solicitar acesso ao áudio do sistema." : "Ative o controle de cada aplicativo no Mixer. O macOS pode solicitar acesso ao áudio do sistema.")).font(.caption).foregroundStyle(.secondary)
        Toggle("Iniciar com o macOS", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
        if let message = login.message { Text(LocalizedStringKey(message)).foregroundStyle(.orange) }
        Toggle("Notificar quando dispositivos mudarem", isOn: Binding(get: { audio.notificationsEnabled }, set: { audio.setNotificationsEnabled($0) }))
        Text("Com o Voltra ativo, ⇧⌘M silencia ou reativa a saída.").font(.caption).foregroundStyle(.secondary)
        Toggle("Atalho global para silenciar a saída", isOn: Binding(get: { shortcut.enabled }, set: { shortcut.setEnabled($0) }))
        Picker("Combinação global", selection: Binding(get: { shortcut.key }, set: { shortcut.setKey($0) })) { ForEach(ShortcutKey.allCases) { Text($0.label).tag($0) } }
        if let message = shortcut.message { Text(message).foregroundStyle(.orange) }
        Text("O controle por aplicativo pode solicitar permissão para gravar áudio do sistema.").foregroundStyle(.secondary)
    } } }
}
struct UnavailableView: View { let title: String; let detail: String; let icon: String
    var body: some View { Panel { VStack(alignment: .leading, spacing: 12) { Image(systemName: icon).font(.largeTitle).foregroundStyle(accent); Text(title).font(.headline); Text(detail).foregroundStyle(.secondary) } } }
}
struct CompactView: View {
    @AppStorage("languagePreference") var languagePreference = "system"
    @EnvironmentObject var audio: AudioService
    @Environment(\.openWindow) var openWindow
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    BrandMark(size: 26)
                    Text("Voltra").font(.headline)
                    Spacer()
                    Button("Abrir") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
                }
                if let error = audio.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("Dispensar") { audio.error = nil }
                }
                ProfileSelector()
                VolumeView()
                Divider()
                DevicePicker(input: false)
                DevicePicker(input: true)
                Divider()
                AppsView(compact: true)
                Button("Encerrar Voltra") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(height: min(audio.activeApps.isEmpty ? 420 : 620, max(200, (NSScreen.main?.visibleFrame.height ?? 700) - 48)))
        .environment(\.locale, Locale(identifier: VoltraLanguage.resolve(languagePreference)))
    }
}
struct OnboardingView: View {
    @AppStorage("onboardingDone") var done = false
    @EnvironmentObject var audio: AudioService
    @State private var step = 0
    let titles = ["Bem-vindo ao Voltra", "Permissões", "Dispositivos padrão", "Headset preferido", "Troca automática", "Tudo pronto"]
    var body: some View { VStack(alignment: .leading, spacing: 20) {
        HStack { BrandMark(size: 40); (Text("VOLTRA  /  \(step + 1) ") + Text("DE 6")).font(.caption).tracking(2).foregroundStyle(accent) }
        Text(LocalizedStringKey(titles[step])).font(.largeTitle.bold())
        Group { switch step {
        case 0: Text("Controle o áudio e os dispositivos do seu Mac em um só lugar.")
        case 1: Text("O controle por aplicativo solicita acesso ao áudio do sistema ao ser ativado.")
        case 2: VStack(spacing: 16) { DevicePicker(input: false); DevicePicker(input: true) }
        case 3: VStack { PreferredPicker(input: false); PreferredPicker(input: true) }
        case 4: Toggle("Usar headset preferido automaticamente", isOn: $audio.automatic)
        default: Text("Use o ícone na barra de menus para acessar o mixer rapidamente.")
        } }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        HStack { if step > 0 { Button("Voltar") { step -= 1 } }; Spacer(); Button(LocalizedStringKey(step == 5 ? "Começar" : "Continuar")) { if step == 5 { done = true } else { step += 1 } }.buttonStyle(.borderedProminent).tint(accent) }
    }.padding(36).frame(width: 570, height: 390).background(navy) }
}
