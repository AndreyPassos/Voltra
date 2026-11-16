// Manual macOS 15+ diagnostic (Swift 6). Run from the repo with:
// swift Tests/Fixtures/CallOutputProbe.swift
// Set VOLTRA_PROBE_SECONDS=60 to observe an entire start/end transition.
// Set VOLTRA_PROBE_AGGREGATE=1 to render through a private output aggregate.
// Set VOLTRA_PROBE_EXPECT_OUTPUT_UID to compare the physical signal during a
// call whose output independently reports that exact device UID.
// Only the process's own quiet reference tone is tapped. No microphone data.
import CoreAudio
import Foundation
import Synchronization
import AppKit

func address(_ selector: UInt32, _ scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func check(_ status: OSStatus, _ step: String) throws {
    if status != 0 { throw NSError(domain: step, code: Int(status)) }
}
func scalar(_ object: AudioObjectID, _ selector: UInt32) throws -> UInt32 {
    var a = address(selector), n: UInt32 = 4, v: UInt32 = 0
    try check(AudioObjectGetPropertyData(object, &a, 0, nil, &n, &v), "scalar")
    return v
}
func processObject(_ pid: pid_t) throws -> AudioObjectID {
    var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject), n: UInt32 = 4, pid = pid, v: UInt32 = 0
    try check(AudioObjectGetPropertyData(1, &a, 4, &pid, &n, &v), "process")
    return v
}
func streamCount(_ device: AudioObjectID, _ scope: UInt32) throws -> UInt32 {
    var a = address(kAudioDevicePropertyStreams, scope), size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size), "streams")
    return size / 4
}
func deviceUID(_ device: AudioObjectID) throws -> CFString {
    var property = address(kAudioDevicePropertyDeviceUID)
    var uid: CFString?, size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(device, &property, 0, nil, &size, UnsafeMutableRawPointer($0))
    }
    try check(status, "device UID")
    guard let uid else { throw NSError(domain: "Missing device UID", code: -1) }
    return uid
}
func whatsAppOutputUIDs() throws -> Set<String> {
    var result: Set<String> = []
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "net.whatsapp.WhatsApp") {
        let object = try processObject(app.processIdentifier)
        guard object != 0, try scalar(object, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
        var property = address(kAudioProcessPropertyDevices, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "WhatsApp output size")
        guard size > 0, size % 4 == 0 else { continue }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        try check(devices.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, buffer.baseAddress!)
        }, "WhatsApp output devices")
        for device in devices.prefix(Int(size) / 4) { result.insert(try deviceUID(device) as String) }
    }
    return result
}
func runIO(_ device: AudioObjectID, _ label: String, _ callback: @escaping AudioDeviceIOBlock, _ body: () throws -> Void) throws {
    var proc: AudioDeviceIOProcID?
    try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, DispatchQueue(label: label), callback), label + ".register")
    guard let proc else { throw NSError(domain: label, code: -1) }
    defer { print(label, "unregister", AudioDeviceDestroyIOProcID(device, proc)) }
    try check(AudioDeviceStart(device, proc), label + ".start")
    defer { print(label, "stop", AudioDeviceStop(device, proc)) }
    try body()
}
@available(macOS 15, *)
final class Stats: Sendable {
    let callbacks = Atomic<Int>(0)
    let peak = Atomic<UInt32>(0)
    func add(_ value: Float) {
        var previous = peak.load(ordering: .relaxed)
        while value.bitPattern > previous {
            let result = peak.compareExchange(expected: previous, desired: value.bitPattern, ordering: .relaxed)
            if result.exchanged { return }
            previous = result.original
        }
    }
}
@available(macOS 15, *)
func run() throws {
    let speaker = try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    guard try scalar(speaker, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn,
          try streamCount(speaker, kAudioDevicePropertyScopeInput) == 0,
          try streamCount(speaker, kAudioDevicePropertyScopeOutput) == 1 else {
        throw NSError(domain: "Output must be built-in with one output stream and no input streams", code: -1)
    }
    var outputAggregate: AudioObjectID = 0
    defer {
        if outputAggregate != 0 {
            print("output aggregate destroy", AudioHardwareDestroyAggregateDevice(outputAggregate))
        }
    }
    if ProcessInfo.processInfo.environment["VOLTRA_PROBE_AGGREGATE"] == "1" {
        let uid = try deviceUID(speaker)
        let spec: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voltra private probe output",
            kAudioAggregateDeviceUIDKey: "com.voltra.probeoutput.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]]
        ]
        try check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &outputAggregate), "output aggregate")
        guard outputAggregate != 0,
              try streamCount(outputAggregate, kAudioDevicePropertyScopeInput) == 0,
              try streamCount(outputAggregate, kAudioDevicePropertyScopeOutput) == 1 else {
            throw NSError(domain: "Expected a private aggregate with output only", code: -1)
        }
    }
    let output = outputAggregate == 0 ? speaker : outputAggregate
    print("render_route", outputAggregate == 0 ? "direct" : "private_aggregate")
    var streamAddress = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
    var stream: AudioObjectID = 0, size: UInt32 = 4
    try check(AudioObjectGetPropertyData(output, &streamAddress, 0, nil, &size, &stream), "output stream")
    var formatAddress = address(kAudioStreamPropertyVirtualFormat)
    var format = AudioStreamBasicDescription()
    size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &size, &format), "output format")
    guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
          format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
          format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
          format.mSampleRate.isFinite, format.mSampleRate > 0 else {
        throw NSError(domain: "Unsupported output format", code: -1)
    }
    let rate = format.mSampleRate
    let amplitude: Float = 0.000316
    let source: AudioDeviceIOBlock = { _, _, _, buffers, timestamp in
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard buffer.mNumberChannels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            let start = timestamp.pointee.mSampleTime
            let frames = Int(buffer.mDataByteSize) / (4 * channels)
            for frame in 0..<frames {
                let sample = amplitude * Float(sin((start + Double(frame)) * (2 * .pi * 997 / rate)))
                for channel in 0..<channels { data[frame * channels + channel] = sample }
            }
        }
    }
    try runIO(output, "source", source) {
        let owner = try processObject(getpid())
        guard owner != 0 else { throw NSError(domain: "No own audio process", code: -1) }
        let desc = CATapDescription(stereoMixdownOfProcesses: [owner])
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var tap: AudioObjectID = 0
        try check(AudioHardwareCreateProcessTap(desc, &tap), "tap")
        defer { print("tap destroy", AudioHardwareDestroyProcessTap(tap)) }
        var a = address(kAudioTapPropertyUID), uid: CFString?, n = UInt32(MemoryLayout<CFString?>.size)
        try check(withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(tap, &a, 0, nil, &n, UnsafeMutableRawPointer($0)) }, "tap uid")
        guard let uid else { throw NSError(domain: "Missing tap UID", code: -1) }
        a = address(kAudioTapPropertyFormat)
        var tapFormat = AudioStreamBasicDescription()
        n = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &a, 0, nil, &n, &tapFormat), "tap format")
        guard tapFormat.mFormatID == kAudioFormatLinearPCM, tapFormat.mBitsPerChannel == 32,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
            throw NSError(domain: "Unsupported tap format", code: -1)
        }
        let spec: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voltra private synthetic measurement",
            kAudioAggregateDeviceUIDKey: "com.voltra.measurement.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid]]
        ]
        var aggregate: AudioObjectID = 0
        try check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate), "aggregate")
        defer { print("aggregate destroy", AudioHardwareDestroyAggregateDevice(aggregate)) }
        guard try streamCount(aggregate, kAudioDevicePropertyScopeInput) == 1,
              try streamCount(aggregate, kAudioDevicePropertyScopeOutput) == 0 else {
            throw NSError(domain: "Expected tap-only aggregate", code: -1)
        }
        let stats = Stats()
        let observe: AudioDeviceIOBlock = { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var peak: Float = 0
            for buffer in buffers {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<(Int(buffer.mDataByteSize) / 4) {
                    let value = abs(samples[index])
                    if value.isFinite { peak = max(peak, value) }
                }
            }
            stats.add(peak)
            stats.callbacks.wrappingAdd(1, ordering: .relaxed)
        }
        try runIO(aggregate, "observer", observe) {
            let environment = ProcessInfo.processInfo.environment
            let requested = Double(environment["VOLTRA_PROBE_SECONDS"] ?? "") ?? 0.8
            let seconds = requested.isFinite ? min(120, max(0.8, requested)) : 0.8
            if let target = environment["VOLTRA_PROBE_EXPECT_OUTPUT_UID"] {
                let start = ProcessInfo.processInfo.systemUptime
                var samples = 0
                var baselineSamples = 0
                var minimum: Float = .infinity
                var maximum: Float = 0
                var lastRoute: Set<String>?
                print("observer ready for separate route")
                fflush(stdout)
                while ProcessInfo.processInfo.systemUptime - start < seconds {
                    Thread.sleep(forTimeInterval: 0.05)
                    let peak = Float(bitPattern: stats.peak.exchange(0, ordering: .relaxed))
                    let ratio = peak / amplitude
                    guard let routes = try? whatsAppOutputUIDs() else { continue }
                    if lastRoute != routes {
                        print("WhatsApp output UIDs", routes.sorted())
                        fflush(stdout)
                        lastRoute = routes
                    }
                    if routes.isEmpty && abs(ratio - 1) < 0.01 { baselineSamples += 1 }
                    if routes == [target] {
                        samples += 1
                        minimum = min(minimum, ratio)
                        maximum = max(maximum, ratio)
                    } else if samples >= 20 && routes.isEmpty {
                        break
                    }
                }
                print("baseline_samples", baselineSamples, "dedicated_route_samples", samples, "min_ratio", minimum, "max_ratio", maximum)
                guard baselineSamples >= 5, samples >= 20 else {
                    throw NSError(domain: "Reference or dedicated route was not observed long enough", code: 2)
                }
                guard minimum >= 0.98, maximum <= 1.02 else {
                    throw NSError(domain: "Physical reference departed from the isolation threshold", code: 3)
                }
                return
            }
            if seconds > 1 {
                let start = ProcessInfo.processInfo.systemUptime
                var lastPrinted: Float = -1
                var measuredDuck = false
                var recovered = false
                print("observer ready")
                fflush(stdout)
                while ProcessInfo.processInfo.systemUptime - start < seconds {
                    Thread.sleep(forTimeInterval: 0.025)
                    let peak = Float(bitPattern: stats.peak.exchange(0, ordering: .relaxed))
                    let ratio = peak / amplitude
                    if ratio > 0 && abs(ratio - lastPrinted) > 0.008 {
                        print("seconds", ProcessInfo.processInfo.systemUptime - start, "ratio", ratio)
                        fflush(stdout)
                        lastPrinted = ratio
                    }
                    if ratio > 0 && ratio < 0.10 { measuredDuck = true }
                    if measuredDuck && ratio >= 0.99 {
                        recovered = true
                        break
                    }
                }
                print("measured_duck", measuredDuck, "measured_recovery", recovered)
                guard lastPrinted > 0 else { throw NSError(domain: "Tap did not observe synthetic signal", code: -1) }
                guard recovered else {
                    throw NSError(domain: "Observation ended before a complete attenuation/recovery cycle", code: 2)
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.8)
            let peak = Float(bitPattern: stats.peak.load(ordering: .relaxed))
            let whatsApp = NSRunningApplication.runningApplications(withBundleIdentifier: "net.whatsapp.WhatsApp")
            let active = whatsApp.contains { app in
                guard let object = try? processObject(app.processIdentifier), object != 0 else { return false }
                return (try? scalar(object, kAudioProcessPropertyIsRunningInput)) == 1
            }
            print("callbacks", stats.callbacks.load(ordering: .relaxed), "reference", amplitude, "tap_peak", peak, "ratio", peak / amplitude, "whatsapp_own_input_active", active)
            guard peak > 0 else { throw NSError(domain: "Tap did not observe synthetic signal", code: -1) }
        }
    }
}
if #available(macOS 15, *) {
    do { try run() } catch { print(error); exit(1) }
} else {
    print("This diagnostic requires macOS 15 or later.")
    exit(1)
}
