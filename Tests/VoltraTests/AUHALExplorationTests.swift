import XCTest
import AudioToolbox
import CoreAudio
@testable import Voltra

final class AUHALExplorationTests: XCTestCase {
    func testVirtualDuplexOutputStartsWithInputDisabled() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_AUHAL_TEST"] == "1" else { throw XCTSkip("Teste AUHAL desativado") }
        let suite = "VoltraAUHAL-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AudioService(defaults: defaults, startTimer: false)
        guard let device = service.devices.first(where: { $0.input && $0.output && $0.transport == kAudioDeviceTransportTypeVirtual }) else { throw XCTSkip("Nenhuma saída virtual duplex disponível") }
        let originalInput = service.defaultInput, originalOutput = service.defaultOutput
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let component = try XCTUnwrap(AudioComponentFindNext(nil, &description))
        var instance: AudioComponentInstance?
        func check(_ status: OSStatus, _ operation: String) throws {
            XCTAssertEqual(status, noErr, "\(operation): \(status)")
            if status != noErr { throw NSError(domain: "VoltraAUHALTest", code: Int(status)) }
        }
        try check(AudioComponentInstanceNew(component, &instance), "create")
        let unit = try XCTUnwrap(instance)
        defer { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        var disabled: UInt32 = 0, enabled: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, UInt32(MemoryLayout<UInt32>.size)), "disable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, UInt32(MemoryLayout<UInt32>.size)), "enable output")
        var selected = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size)), "select virtual device")
        if let rateText = ProcessInfo.processInfo.environment["VOLTRA_AUHAL_CLIENT_RATE"], let rate = Double(rateText) {
            var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set client rate")
            var actualFormat = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &actualFormat, &size), "read client rate")
            XCTAssertEqual(actualFormat.mSampleRate, rate, accuracy: 0.01)
        }
        // Access these counters only in the render callback and after AudioOutputUnitStop returns.
        let counters = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
        counters.initialize(repeating: 0, count: 2)
        defer { AudioOutputUnitStop(unit); counters.deinitialize(count: 2); counters.deallocate() }
        var callback = AURenderCallbackStruct(inputProc: { context, _, _, _, frames, data in
            let counters = context.assumingMemoryBound(to: UInt64.self)
            counters[0] += 1; counters[1] += UInt64(frames)
            if let data { for buffer in UnsafeMutableAudioBufferListPointer(data) { if let ptr = buffer.mData { memset(ptr, 0, Int(buffer.mDataByteSize)) } } }
            return noErr
        }, inputProcRefCon: UnsafeMutableRawPointer(counters))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")
        try check(AudioUnitInitialize(unit), "initialize")
        var actual: UInt32 = 1, size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &actual, &size), "read input state")
        XCTAssertEqual(actual, 0)
        let measureRate = ProcessInfo.processInfo.environment["VOLTRA_AUHAL_MEASURE_RATE"] == "1"
        let startedAt = ProcessInfo.processInfo.systemUptime
        try check(AudioOutputUnitStart(unit), "start")
        Thread.sleep(forTimeInterval: measureRate ? 2 : 0.25)
        try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &actual, &size), "read running input state")
        XCTAssertEqual(actual, 0)
        try check(AudioOutputUnitStop(unit), "stop")
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        XCTAssertGreaterThan(counters[0], 0, "A saída deve solicitar buffers")
        if measureRate, let rateText = ProcessInfo.processInfo.environment["VOLTRA_AUHAL_CLIENT_RATE"], let rate = Double(rateText) {
            let observed = Double(counters[1]) / elapsed
            print("VOLTRA_AUHAL_RATE requested=\(rate) observed=\(observed) callbacks=\(counters[0])")
            XCTAssertEqual(observed, rate, accuracy: rate * 0.15)
        }
        service.refresh()
        XCTAssertEqual(service.defaultInput, originalInput)
        XCTAssertEqual(service.defaultOutput, originalOutput)
    }
    func testPhysicalInputNotStartedByOutputOnlyAggregate() throws {
        guard ProcessInfo.processInfo.environment["VOLTRA_PHYSICAL_ISOLATION_TEST"] == "1" else { throw XCTSkip("Teste físico de isolamento desativado") }
        let suite = "VoltraPhysicalIsolation-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AudioService(defaults: defaults, startTimer: false)
        let input = try XCTUnwrap(service.devices.first(where: { $0.input && $0.builtIn && !$0.output }))
        let output = try XCTUnwrap(service.devices.first(where: { $0.output && $0.builtIn && !$0.input }))
        let originalInput = service.defaultInput, originalOutput = service.defaultOutput
        func check(_ status: OSStatus, _ step: String) throws {
            XCTAssertEqual(status, noErr, "\(step): \(status)")
            if status != noErr { throw NSError(domain: "VoltraPhysicalIsolation", code: Int(status)) }
        }
        func runningInput() throws -> UInt32 {
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioObjectGetPropertyData(input.id, &property, 0, nil, &size, &value), "input activity")
            return value
        }
        guard try runningInput() == 0 else { throw XCTSkip("Microfone já está em uso") }
        let spec: [String: Any] = [kAudioAggregateDeviceNameKey: "Voltra Isolation Test", kAudioAggregateDeviceUIDKey: "com.voltra.aggregate.isolation.\(UUID().uuidString)", kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceMainSubDeviceKey: output.uid, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid], [kAudioSubDeviceUIDKey: input.uid]]]
        let directOutput = ProcessInfo.processInfo.environment["VOLTRA_PHYSICAL_DIRECT_OUTPUT"] == "1"
        var aggregate: AudioObjectID = 0
        if !directOutput { try check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &aggregate), "create aggregate") }
        defer { if aggregate != 0 { XCTAssertEqual(AudioHardwareDestroyAggregateDevice(aggregate), noErr) } }
        let afterDevice = try runningInput()
        if ProcessInfo.processInfo.environment["VOLTRA_PHYSICAL_IOPROC_TEST"] == "1" {
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamBytes: UInt32 = 0
            try check(AudioObjectGetPropertyDataSize(aggregate, &streamAddress, 0, nil, &streamBytes), "input stream count")
            guard streamBytes == UInt32(MemoryLayout<AudioObjectID>.size) else { throw XCTSkip("O agregado de teste não possui exatamente um fluxo de entrada") }
            var io: AudioDeviceIOProcID?
            let queue = DispatchQueue(label: "com.voltra.physical-stream-probe")
            let callback: AudioDeviceIOBlock = { _, _, _, output, _ in
                for buffer in UnsafeMutableAudioBufferListPointer(output) { if let ptr = buffer.mData { memset(ptr, 0, Int(buffer.mDataByteSize)) } }
            }
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, queue, callback), "create IOProc")
            let proc = try XCTUnwrap(io)
            defer { XCTAssertEqual(AudioDeviceDestroyIOProcID(aggregate, proc), noErr) }
            var usage = AudioHardwareIOProcStreamUsage(mIOProc: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), mNumberStreams: 1, mStreamIsOn: 0)
            var usageAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var usageBytes = UInt32(MemoryLayout<AudioHardwareIOProcStreamUsage>.size)
            try check(AudioObjectSetPropertyData(aggregate, &usageAddress, 0, nil, usageBytes, &usage), "disable input stream")
            usage.mStreamIsOn = 1
            try check(AudioObjectGetPropertyData(aggregate, &usageAddress, 0, nil, &usageBytes, &usage), "read input stream usage")
            XCTAssertEqual(usage.mStreamIsOn, 0)
            try check(AudioDeviceStart(aggregate, proc), "start IOProc")
            Thread.sleep(forTimeInterval: 0.5)
            let during = try runningInput()
            try check(AudioDeviceStop(aggregate, proc), "stop IOProc")
            let stopped = try runningInput()
            print("VOLTRA_PHYSICAL_IOPROC afterDevice=\(afterDevice) inputEnabled=\(usage.mStreamIsOn) running=\(during) afterStop=\(stopped)")
            XCTAssertEqual(during, 0, "O microfone físico começou a operar mesmo com o fluxo desativado")
            return
        }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let component = try XCTUnwrap(AudioComponentFindNext(nil, &description))
        var instance: AudioComponentInstance?
        try check(AudioComponentInstanceNew(component, &instance), "create output")
        let unit = try XCTUnwrap(instance)
        var initialized = false, started = false
        defer { if started { AudioOutputUnitStop(unit) }; if initialized { AudioUnitUninitialize(unit) }; AudioComponentInstanceDispose(unit) }
        var disabled: UInt32 = 0, enabled: UInt32 = 1, selected = directOutput ? output.id : aggregate
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, UInt32(MemoryLayout<UInt32>.size)), "disable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, UInt32(MemoryLayout<UInt32>.size)), "enable output")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size)), "select aggregate")
        var callback = AURenderCallbackStruct(inputProc: { _, _, _, _, _, data in
            if let data { for buffer in UnsafeMutableAudioBufferListPointer(data) { if let ptr = buffer.mData { memset(ptr, 0, Int(buffer.mDataByteSize)) } } }
            return noErr
        }, inputProcRefCon: nil)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")
        try check(AudioUnitInitialize(unit), "initialize"); initialized = true
        var inputEnabled: UInt32 = 1, size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &inputEnabled, &size), "input enabled")
        XCTAssertEqual(inputEnabled, 0)
        let afterInitialize = try runningInput()
        try check(AudioOutputUnitStart(unit), "start output"); started = true
        Thread.sleep(forTimeInterval: 0.5)
        let inputRunning = try runningInput()
        try check(AudioOutputUnitStop(unit), "stop output"); started = false
        let afterStop = try runningInput()
        print("VOLTRA_PHYSICAL_ISOLATION direct=\(directOutput) afterDevice=\(afterDevice) afterInitialize=\(afterInitialize) running=\(inputRunning) afterStop=\(afterStop)")
        XCTAssertEqual(afterDevice, 0, "O microfone físico começou a operar ao criar o dispositivo")
        XCTAssertEqual(afterInitialize, 0, "O microfone físico começou a operar ao inicializar a saída")
        XCTAssertEqual(inputRunning, 0, "O microfone físico começou a operar")
        service.refresh()
        XCTAssertEqual(service.defaultInput, originalInput)
        XCTAssertEqual(service.defaultOutput, originalOutput)
    }

}
