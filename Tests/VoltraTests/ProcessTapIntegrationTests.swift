import XCTest
import CoreAudio
@testable import Voltra

final class ProcessTapIntegrationTests: XCTestCase {
    func testTapCapturesAndAppliesGain() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Requer macOS 14.2") }
        guard ProcessInfo.processInfo.environment["VOLTRA_TAP_TEST"] == "1" else { throw XCTSkip("Teste de captura desativado") }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("voltra-tone-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: path) }
        var wav = Data()
        func integer<T: FixedWidthInteger>(_ n: T) { var v = n.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        let environment = ProcessInfo.processInfo.environment
        let duration = min(120, max(2, Int(environment["VOLTRA_TAP_SECONDS"] ?? "") ?? (environment["VOLTRA_TAP_LONG"] == "1" ? 15 : 2)))
        // NSSound loops the file; a short fixture is sufficient even for long runs.
        let frames = 44100 * 10
        wav.append(contentsOf: Array("RIFF".utf8)); integer(UInt32(36 + frames * 4)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(2)); integer(UInt32(44100)); integer(UInt32(44100 * 4)); integer(UInt16(4)); integer(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); integer(UInt32(frames * 4))
        for frame in 0..<frames { let sample = Int16(2000 * sin(2 * Double.pi * 440 * Double(frame) / 44100)); integer(sample); integer(sample) }
        try wav.write(to: path)
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("VoltraFixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let bundle = fixtureRoot.appendingPathComponent("VoltraTone.app/Contents")
        let binary = bundle.appendingPathComponent("MacOS/VoltraTone")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": "VoltraTone", "CFBundleIdentifier": "com.voltra.test-tone", "CFBundleName": "VoltraTone", "CFBundlePackageType": "APPL"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: bundle.appendingPathComponent("Info.plist"))
        if let fixture = ProcessInfo.processInfo.environment["VOLTRA_FIXTURE_BINARY"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: binary)
        } else {
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/AudioSource.swift")
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["swiftc", source.path, "-o", binary.path]
            try compiler.run(); compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0)
        }
        let suite = "VoltraIntegration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let simulateCleanupFailure = ProcessInfo.processInfo.environment["VOLTRA_SERVICE_CLEANUP_FAILURE"] == "1"
        let simulateStandardServiceFailure = ProcessInfo.processInfo.environment["VOLTRA_STANDARD_SERVICE_CLEANUP_FAILURE"] == "1"
        var hiddenDeviceUID: String?
        var replacementIDForUID: String?
        let service = AudioService(defaults: defaults, startTimer: false, duplexCleanupResult: { status in simulateCleanupFailure && status == noErr ? -1 : status }, standardCleanupResult: { status in simulateStandardServiceFailure && status == noErr ? -1 : status }, deviceVisible: { $0.uid != hiddenDeviceUID }, sessionDeviceID: { device in device.uid == replacementIDForUID ? device.id &+ 1000000 : device.id }, virtualCaptureRateOverride: ProcessInfo.processInfo.environment["VOLTRA_SERVICE_DIFFERENT_RATE"] == "1" ? 44100 : nil)
        if ProcessInfo.processInfo.environment["VOLTRA_AUTOMATION_TEST"] == "1" {
            let input = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultInput }))
            let output = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultOutput }))
            let marker = AppMix(volume: 0.17, muted: true)
            let profile = AudioProfile(id: UUID(), name: "Teste de abertura", inputUID: input.uid, outputUID: output.uid, volume: nil, appMix: ["automation-marker": marker])
            service.profiles.append(profile)
            service.addLaunchRule(bundleID: "com.voltra.test-tone", profileID: profile.id)
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = [path.path]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        var target: AudioObjectID = 0
        for _ in 0..<30 {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = process.processIdentifier
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &target)
            if target != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertNotEqual(target, 0)
        if ProcessInfo.processInfo.environment["VOLTRA_AUTOMATION_TEST"] == "1" {
            let deadline = Date().addingTimeInterval(8)
            while service.appSettings["automation-marker"] == nil && Date() < deadline {
                service.refresh()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            XCTAssertEqual(service.appSettings["automation-marker"]?.volume, 0.17)
            XCTAssertEqual(service.appSettings["automation-marker"]?.muted, true)
        }
        let originalInput = service.defaultInput
        defer { if ProcessInfo.processInfo.environment["VOLTRA_TAP_HFP"] == "1" { service.setDefault(originalInput, input: true) } }
        if ProcessInfo.processInfo.environment["VOLTRA_TAP_HFP"] == "1" {
            let outputName = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultOutput })?.name)
            guard let microphone = service.devices.first(where: { $0.input && !$0.builtIn && $0.name == outputName }) else { throw XCTSkip("Headset com entrada e saída correspondentes não está conectado") }
            XCTAssertTrue(service.setDefault(microphone.id, input: true))
            let deadline = Date().addingTimeInterval(8)
            var rate: Float64 = 0
            repeat {
                var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var size = UInt32(MemoryLayout<Float64>.size)
                _ = AudioObjectGetPropertyData(service.defaultOutput, &address, 0, nil, &size, &rate)
                if rate > 0 && rate <= 24000 { break }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < deadline
            XCTAssertGreaterThan(rate, 0)
            XCTAssertLessThanOrEqual(rate, 24000, "O headset não mudou para o perfil de chamada")
        }
        let useDefault = ProcessInfo.processInfo.environment["VOLTRA_TAP_OUTPUT"] == "default"
        let useDuplex = ProcessInfo.processInfo.environment["VOLTRA_TAP_DUPLEX"] == "1"
        let output = try XCTUnwrap(service.devices.first { useDuplex ? ($0.output && $0.input && !$0.builtIn) : (useDefault ? $0.id == service.defaultOutput : ($0.output && $0.builtIn)) })
        if !useDuplex {
            let deadline = Date().addingTimeInterval(8)
            var previous: Float64 = -1
            var stableSince = Date()
            while Date() < deadline {
                var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var size = UInt32(MemoryLayout<Float64>.size)
                var rate: Float64 = 0
                let status = AudioObjectGetPropertyData(output.id, &property, 0, nil, &size, &rate)
                if status == noErr && rate > 0 && rate == previous {
                    if Date().timeIntervalSince(stableSince) >= 2 { break }
                } else { previous = rate; stableSince = Date() }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        let simulateStandardCleanupFailure = ProcessInfo.processInfo.environment["VOLTRA_STANDARD_CLEANUP_FAILURE"] == "1"
        let tap = ProcessTap(cleanupResult: { status in simulateStandardCleanupFailure && status == noErr ? -1 : status })
        let silentLong = environment["VOLTRA_TAP_SILENT_LONG"] == "1"
        tap.setGain(0.5, muted: silentLong)
        if useDuplex {
            XCTAssertThrowsError(try tap.start(processes: [target], output: output))
            XCTAssertFalse(tap.running)
            return
        }
        try tap.start(processes: [target], output: output)
        defer { tap.stop() }
        Thread.sleep(forTimeInterval: Double(duration))
        if silentLong {
            XCTAssertGreaterThan(tap.diagnostics.1, 0.001)
            XCTAssertEqual(tap.diagnostics.2, 0, accuracy: 0.00001)
            tap.setGain(0.5, muted: false)
            Thread.sleep(forTimeInterval: 0.4)
        }
        let (calls, input, rendered) = tap.diagnostics
        print("VOLTRA_TAP_DIAGNOSTICS callbacks=\(calls) input=\(input) output=\(rendered) frames=\(tap.bufferFrames) underruns=\(tap.underruns) overruns=\(tap.overruns)")
        XCTAssertEqual(tap.underruns, 0, "Ocorreram lacunas na reprodução")
        XCTAssertEqual(tap.overruns, 0, "O buffer de áudio transbordou")
        XCTAssertGreaterThan(calls, 0)
        XCTAssertGreaterThan(input, 0.001, "Captura silenciosa: verifique permissão de áudio do sistema")
        XCTAssertEqual(rendered / input, 0.5, accuracy: 0.02)
        if environment["VOLTRA_STANDARD_SELF_PROBE"] == "1" {
            let observed = try SelfOutputProbe.peak()
            guard observed.frames > 1024 else { throw XCTSkip("O Process Tap não forneceu quadros do próprio processo") }
            XCTAssertEqual(observed.peak, rendered, accuracy: 0.005)
            tap.setGain(0.5, muted: true)
            Thread.sleep(forTimeInterval: 0.2)
            let silent = try SelfOutputProbe.peak()
            XCTAssertGreaterThan(silent.frames, 1024)
            XCTAssertEqual(silent.peak, 0, accuracy: 0.00001)
            tap.setGain(0.5, muted: false)
            Thread.sleep(forTimeInterval: 0.2)
            let restored = try SelfOutputProbe.peak()
            XCTAssertGreaterThan(restored.frames, 1024)
            XCTAssertEqual(restored.peak, rendered, accuracy: 0.005)
            print("VOLTRA_STANDARD_SELF_PROBE signal=\(observed.peak) muted=\(silent.peak) restored=\(restored.peak)")
        }
        tap.setGain(0.5, muted: true)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertGreaterThan(tap.diagnostics.1, 0.001)
        XCTAssertEqual(tap.diagnostics.2, 0, accuracy: 0.00001)
        tap.stop()
        if simulateStandardCleanupFailure {
            XCTAssertTrue(tap.cleanupFailed)
            tap.stop()
            XCTAssertTrue(tap.cleanupFailed)
            return
        }
        XCTAssertFalse(tap.cleanupFailed)
        for _ in 0..<20 {
            service.refresh()
            if service.activeApps.contains(where: { $0.processes.contains(target) }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let detected = try XCTUnwrap(service.activeApps.first(where: { $0.processes.contains(target) }), "A fonte real deve aparecer na lista de aplicativos")
        XCTAssertEqual(detected.id, "com.voltra.test-tone")
        func waitForControl() {
            let deadline = Date().addingTimeInterval(8)
            while service.startingApps.contains(detected.id) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        service.setAutomaticAppControl(true)
        waitForControl()
        XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "O controle automático não iniciou")
        if simulateStandardServiceFailure {
            service.retryApp(detected)
            let deadline = Date().addingTimeInterval(5)
            while !service.quarantinedApps.contains(detected.id) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertTrue(service.quarantinedApps.contains(detected.id))
            service.refresh()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertFalse(service.controlledApps.contains(detected.id))
            XCTAssertFalse(service.startingApps.contains(detected.id))
            XCTAssertNotNil(service.error)
            return
        }
        service.retryApp(detected)
        waitForControl()
        XCTAssertFalse(service.controlPreferences.enabled.contains(detected.id), "Tentar novamente no modo automático não deve criar ativação manual")
        service.stopApp(detected.id)
        service.refresh()
        XCTAssertTrue(service.desiredApps.contains(detected.id), "O modo automático controla todos os aplicativos ativos")
        service.setAutomaticAppControl(false)
        service.stopApp(detected.id)
        service.refresh()
        XCTAssertFalse(service.desiredApps.contains(detected.id))
        service.startApp(detected)
        waitForControl()
        XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "")
        service.setAppMix(detected, volume: 0.3, muted: true)
        if ProcessInfo.processInfo.environment["VOLTRA_DEVICE_ID_RECREATION_TEST"] == "1" {
            let output = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultOutput && !$0.input }))
            service.setAppOutput(detected, uid: output.uid)
            waitForControl()
            XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "")
            replacementIDForUID = output.uid
            service.refresh()
            XCTAssertTrue(service.startingApps.contains(detected.id), "Novo objeto com mesmo UID deve iniciar outra sessão")
            XCTAssertFalse(service.controlledApps.contains(detected.id))
            waitForControl()
            XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "")
            XCTAssertEqual(service.activeOutputUID(for: detected.id), output.uid)
            XCTAssertTrue(service.settings(for: detected.id).muted)
            Thread.sleep(forTimeInterval: 0.3)
            let replacement = try XCTUnwrap(service.sessionDiagnostics(for: detected.id))
            XCTAssertGreaterThan(replacement.1, 0.001)
            XCTAssertEqual(replacement.2, 0, accuracy: 0.00001)
            replacementIDForUID = nil
            service.refresh()
            waitForControl()
            service.setAppOutput(detected, uid: nil)
            waitForControl()
        }
        if ProcessInfo.processInfo.environment["VOLTRA_ROUTE_VISIBILITY_TEST"] == "1" {
            let chosen = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultOutput && !$0.input }))
            service.setAppOutput(detected, uid: chosen.uid)
            waitForControl()
            XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "")
            XCTAssertEqual(service.activeOutputUID(for: detected.id), chosen.uid)
            hiddenDeviceUID = chosen.uid
            service.refresh()
            XCTAssertFalse(service.controlledApps.contains(detected.id))
            XCTAssertEqual(service.settings(for: detected.id).outputUID, chosen.uid)
            XCTAssertTrue(service.desiredApps.contains(detected.id))
            hiddenDeviceUID = nil
            service.refresh()
            waitForControl()
            XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "Saída não retomou")
            XCTAssertEqual(service.activeOutputUID(for: detected.id), chosen.uid)
            XCTAssertEqual(service.settings(for: detected.id).volume, 0.3, accuracy: 0.001)
            XCTAssertTrue(service.settings(for: detected.id).muted)
            Thread.sleep(forTimeInterval: 0.3)
            let resumed = try XCTUnwrap(service.sessionDiagnostics(for: detected.id))
            XCTAssertGreaterThan(resumed.1, 0.001)
            XCTAssertEqual(resumed.2, 0, accuracy: 0.00001)
            service.setAppOutput(detected, uid: nil)
            waitForControl()
        }
        if ProcessInfo.processInfo.environment["VOLTRA_ROUTE_RECONNECT_TEST"] == "1" {
            let speaker = try XCTUnwrap(service.devices.first(where: { $0.output && $0.builtIn && !$0.input }))
            let uid = "com.voltra.route-test." + UUID().uuidString
            let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "Voltra Route Test", kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceMainSubDeviceKey: speaker.uid, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: speaker.uid]]]
            var device: AudioObjectID = 0
            func createDevice() throws {
                let status = AudioHardwareCreateAggregateDevice(spec as CFDictionary, &device)
                XCTAssertEqual(status, noErr)
                if status != noErr { throw NSError(domain: "VoltraRouteReconnect", code: Int(status)) }
            }
            try createDevice()
            defer { if device != 0 { AudioHardwareDestroyAggregateDevice(device) } }
            service.refresh()
            guard service.devices.contains(where: { $0.uid == uid && $0.output }) else { throw XCTSkip("O agregado de teste não está disponível como saída") }
            if ProcessInfo.processInfo.environment["VOLTRA_PROBE_NESTED_STREAMS"] == "1" {
                let description = CATapDescription(stereoMixdownOfProcesses: [target]); description.isPrivate = true; description.muteBehavior = .unmuted
                var probeTap: AudioObjectID = 0
                XCTAssertEqual(AudioHardwareCreateProcessTap(description, &probeTap), noErr)
                guard probeTap != 0 else { return }
                defer { XCTAssertEqual(AudioHardwareDestroyProcessTap(probeTap), noErr) }
                var tapAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var tapUID: CFString?, tapSize = UInt32(MemoryLayout<CFString?>.size)
                let tapStatus = withUnsafeMutablePointer(to: &tapUID) { AudioObjectGetPropertyData(probeTap, &tapAddress, 0, nil, &tapSize, UnsafeMutableRawPointer($0)) }
                XCTAssertEqual(tapStatus, noErr)
                let probeUID = try XCTUnwrap(tapUID)
                let probeSpec: [String: Any] = [kAudioAggregateDeviceNameKey: "Voltra Stream Probe", kAudioAggregateDeviceUIDKey: "com.voltra.probe." + UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]], kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: probeUID]]]
                var probe: AudioObjectID = 0
                XCTAssertEqual(AudioHardwareCreateAggregateDevice(probeSpec as CFDictionary, &probe), noErr)
                guard probe != 0 else { return }
                defer { XCTAssertEqual(AudioHardwareDestroyAggregateDevice(probe), noErr) }
                var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
                var bytes: UInt32 = 0
                XCTAssertEqual(AudioObjectGetPropertyDataSize(probe, &streamAddress, 0, nil, &bytes), noErr)
                var streams = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
                guard !streams.isEmpty else { throw XCTSkip("O agregado aninhado não expôs fluxos de saída") }
                let status = streams.withUnsafeMutableBytes { AudioObjectGetPropertyData(probe, &streamAddress, 0, nil, &bytes, $0.baseAddress!) }
                XCTAssertEqual(status, noErr)
                print("VOLTRA_NESTED_OUTPUT_STREAMS count=\(streams.count)")
                for (index, stream) in streams.enumerated() {
                    var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                    var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                    XCTAssertEqual(AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format), noErr)
                    print("VOLTRA_NESTED_STREAM index=\(index) rate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame) flags=\(format.mFormatFlags) bytes=\(format.mBytesPerFrame)")
                }
                var config = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
                var configSize: UInt32 = 0
                XCTAssertEqual(AudioObjectGetPropertyDataSize(probe, &config, 0, nil, &configSize), noErr)
                guard configSize >= MemoryLayout<AudioBufferList>.size else { XCTFail("Configuração de saída inválida"); return }
                let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
                defer { storage.deallocate() }
                XCTAssertEqual(AudioObjectGetPropertyData(probe, &config, 0, nil, &configSize, storage), noErr)
                let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
                print("VOLTRA_NESTED_BUFFERS channels=\(buffers.map { $0.mNumberChannels })")
            }
            service.setAppOutput(detected, uid: uid)
            waitForControl()
            guard service.controlledApps.contains(detected.id) else {
                let reason = service.error ?? "Saída privada não iniciou"
                service.setAppOutput(detected, uid: nil)
                waitForControl()
                if reason.localizedCaseInsensitiveContains("não possui fluxos") || reason.localizedCaseInsensitiveContains("no available streams") {
                    throw XCTSkip("O agregado aninhado não expõe fluxos de saída: \(reason)")
                }
                XCTFail("Saída privada não iniciou: \(reason)")
                return
            }
            XCTAssertEqual(service.activeOutputUID(for: detected.id), uid)
            let status = AudioHardwareDestroyAggregateDevice(device)
            XCTAssertEqual(status, noErr)
            if status == noErr { device = 0 }
            let goneDeadline = Date().addingTimeInterval(5)
            repeat { service.refresh(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)) } while service.devices.contains(where: { $0.uid == uid }) && Date() < goneDeadline
            XCTAssertFalse(service.devices.contains(where: { $0.uid == uid }))
            XCTAssertFalse(service.controlledApps.contains(detected.id))
            XCTAssertEqual(service.settings(for: detected.id).outputUID, uid)
            try createDevice()
            let restoredDeadline = Date().addingTimeInterval(10)
            repeat { service.refresh(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)) } while !service.controlledApps.contains(detected.id) && Date() < restoredDeadline
            XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "Saída privada não retomou")
            XCTAssertEqual(service.activeOutputUID(for: detected.id), uid)
            XCTAssertTrue(service.settings(for: detected.id).muted)
            service.setAppOutput(detected, uid: nil)
            waitForControl()
        }
        if ProcessInfo.processInfo.environment["VOLTRA_VIRTUAL_DUPLEX_TEST"] == "1" {
            let virtual = try XCTUnwrap(service.devices.first(where: { $0.output && $0.input && $0.transport == kAudioDeviceTransportTypeVirtual }))
            service.setAppOutput(detected, uid: virtual.uid)
            waitForControl()
            XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "Virtual duplex não iniciou")
            XCTAssertEqual(service.activeOutputUID(for: detected.id), virtual.uid)
            if ProcessInfo.processInfo.environment["VOLTRA_SERVICE_DIFFERENT_RATE"] == "1" {
                XCTAssertEqual(service.sessionClientRate(for: detected.id) ?? 0, 44100, accuracy: 0.01)
            }
            service.setAppMix(detected, volume: 0.5, muted: false)
            Thread.sleep(forTimeInterval: 0.5)
            let playing = try XCTUnwrap(service.sessionDiagnostics(for: detected.id))
            XCTAssertGreaterThan(playing.1, 0.001)
            XCTAssertEqual(playing.2 / playing.1, 0.5, accuracy: 0.02)
            if ProcessInfo.processInfo.environment["VOLTRA_PROFILE_ROUTE_TEST"] == "1" {
                let input = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultInput }))
                let output = try XCTUnwrap(service.devices.first(where: { $0.id == service.defaultOutput }))
                let ordinary = AudioProfile(id: UUID(), name: "Ordinary", inputUID: input.uid, outputUID: output.uid, volume: nil, appMix: [detected.id: AppMix(volume: 0.25, muted: false)], outputMuted: nil)
                var virtualMix = AppMix(volume: 0.5, muted: false); virtualMix.outputUID = virtual.uid
                let routed = AudioProfile(id: UUID(), name: "Virtual", inputUID: input.uid, outputUID: output.uid, volume: nil, appMix: [detected.id: virtualMix], outputMuted: nil)
                service.profiles.append(contentsOf: [ordinary, routed])
                XCTAssertTrue(service.applyProfile(ordinary), service.error ?? "")
                waitForControl()
                XCTAssertEqual(service.activeProfileID, ordinary.id)
                XCTAssertEqual(service.activeOutputUID(for: detected.id), output.uid)
                Thread.sleep(forTimeInterval: 0.4)
                let first = try XCTUnwrap(service.sessionDiagnostics(for: detected.id))
                XCTAssertGreaterThan(first.1, 0.001)
                XCTAssertEqual(first.2 / first.1, 0.25, accuracy: 0.02)
                service.setAppMix(detected, volume: 0.35)
                XCTAssertEqual(service.profiles.first(where: { $0.id == routed.id })?.appMix?[detected.id]?.volume, 0.5)
                let updatedOrdinary = try XCTUnwrap(service.profiles.first(where: { $0.id == ordinary.id }))
                XCTAssertEqual(updatedOrdinary.appMix?[detected.id]?.volume, 0.35)
                XCTAssertTrue(service.applyProfile(routed), service.error ?? "")
                waitForControl()
                XCTAssertEqual(service.activeProfileID, routed.id)
                XCTAssertEqual(service.activeOutputUID(for: detected.id), virtual.uid)
                Thread.sleep(forTimeInterval: 0.4)
                let second = try XCTUnwrap(service.sessionDiagnostics(for: detected.id))
                XCTAssertGreaterThan(second.1, 0.001)
                XCTAssertEqual(second.2 / second.1, 0.5, accuracy: 0.02)
                XCTAssertTrue(service.applyProfile(updatedOrdinary), service.error ?? "")
                waitForControl()
                Thread.sleep(forTimeInterval: 0.4)
                let restored = try XCTUnwrap(service.sessionDiagnostics(for: detected.id))
                XCTAssertEqual(service.activeOutputUID(for: detected.id), output.uid)
                XCTAssertGreaterThan(restored.1, 0.001)
                XCTAssertEqual(restored.2 / restored.1, 0.35, accuracy: 0.02)
                XCTAssertTrue(service.applyProfile(routed), service.error ?? "")
                waitForControl()
                XCTAssertEqual(service.activeOutputUID(for: detected.id), virtual.uid)
            }
            if ProcessInfo.processInfo.environment["VOLTRA_VIRTUAL_STABILITY_TEST"] == "1" {
                let deadline = Date().addingTimeInterval(12)
                while Date() < deadline {
                    service.refresh()
                    if !service.controlledApps.contains(detected.id) { break }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
                XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "A sessão virtual foi interrompida")
                XCTAssertEqual(service.activeOutputUID(for: detected.id), virtual.uid)
            }
            service.setAppMix(detected, muted: true)
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertEqual(try XCTUnwrap(service.sessionDiagnostics(for: detected.id)).2, 0, accuracy: 0.00001)
            if ProcessInfo.processInfo.environment["VOLTRA_ROUTE_VISIBILITY_TEST"] == "1" {
                hiddenDeviceUID = virtual.uid
                service.refresh()
                XCTAssertFalse(service.controlledApps.contains(detected.id))
                XCTAssertEqual(service.settings(for: detected.id).outputUID, virtual.uid)
                XCTAssertTrue(service.desiredApps.contains(detected.id))
                hiddenDeviceUID = nil
                service.refresh()
                waitForControl()
                XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "Saída virtual não retomou")
                XCTAssertEqual(service.activeOutputUID(for: detected.id), virtual.uid)
                XCTAssertTrue(service.settings(for: detected.id).muted)
                Thread.sleep(forTimeInterval: 0.3)
                let resumed = try XCTUnwrap(service.sessionDiagnostics(for: detected.id))
                XCTAssertGreaterThan(resumed.1, 0.001)
                XCTAssertEqual(resumed.2, 0, accuracy: 0.00001)
            }
            if simulateCleanupFailure {
                service.setAppOutput(detected, uid: nil)
                let deadline = Date().addingTimeInterval(5)
                while !service.quarantinedApps.contains(detected.id) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                XCTAssertTrue(service.quarantinedApps.contains(detected.id))
                service.retryApp(detected)
                service.refresh()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                XCTAssertFalse(service.controlledApps.contains(detected.id))
                XCTAssertFalse(service.startingApps.contains(detected.id))
                XCTAssertNotNil(service.error)
                return
            }
            service.setAppOutput(detected, uid: "unavailable-output-" + UUID().uuidString)
            XCTAssertFalse(service.controlledApps.contains(detected.id))
            XCTAssertNil(service.activeOutputUID(for: detected.id))
            XCTAssertTrue(service.desiredApps.contains(detected.id))
            service.setAppOutput(detected, uid: virtual.uid)
            waitForControl()
            XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "Saída virtual não retomou")
            XCTAssertTrue(service.settings(for: detected.id).muted)
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertEqual(try XCTUnwrap(service.sessionDiagnostics(for: detected.id)).2, 0, accuracy: 0.00001)
            service.setAppOutput(detected, uid: nil)
            waitForControl()
            XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "Saída padrão não retomou")
            service.setAppMix(detected, volume: 0.3, muted: true)
        }
        if let alternate = service.devices.first(where: { $0.output && !$0.input && $0.id != service.defaultOutput }) {
            service.setAppOutput(detected, uid: alternate.uid)
            waitForControl()
            XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "")
            XCTAssertEqual(service.activeOutputUID(for: detected.id), alternate.uid)
        }
        XCTAssertEqual(service.settings(for: detected.id).volume, 0.3, accuracy: 0.001)
        process.terminate()
        process.waitUntilExit()
        let removalDeadline = Date().addingTimeInterval(5)
        while service.controlledApps.contains(detected.id) && Date() < removalDeadline {
            service.refresh()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(service.controlledApps.contains(detected.id))
        XCTAssertTrue(service.desiredApps.contains(detected.id))
        // The next launch must be picked up solely by automatic mode, not by a saved manual activation.
        service.stopApp(detected.id)
        service.setAutomaticAppControl(true)
        XCTAssertFalse(service.desiredApps.contains(detected.id))
        let restarted = Process()
        restarted.executableURL = binary
        restarted.arguments = [path.path]
        try restarted.run()
        defer { if restarted.isRunning { restarted.terminate() } }
        let restartDeadline = Date().addingTimeInterval(25)
        while !service.controlledApps.contains(detected.id) && Date() < restartDeadline {
            service.refresh()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if !service.controlledApps.contains(detected.id) {
            print("VOLTRA_RESTART_DIAGNOSTICS running=\(restarted.isRunning) desired=\(service.desiredApps.contains(detected.id)) starting=\(service.startingApps.contains(detected.id)) stalled=\(service.stalledStarts.contains(detected.id)) active=\(service.activeApps.map { $0.id }) output=\(service.settings(for: detected.id).outputUID ?? "default") error=\(service.error ?? "none")")
        }
        XCTAssertTrue(service.controlledApps.contains(detected.id), service.error ?? "O controle não retornou após reinício")
        XCTAssertTrue(service.settings(for: detected.id).muted)
        service.setAutomaticAppControl(false)
        service.stopApp(detected.id)
        XCTAssertFalse(service.controlledApps.contains(detected.id))
    }
}
