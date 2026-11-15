import XCTest
import CoreAudio
@testable import Voltra
final class AppRouteTests: XCTestCase {
    let builtIn = AudioDevice(id: 1, uid: "mac", name: "Mac", input: false, output: true, builtIn: true)
    let headphones = AudioDevice(id: 2, uid: "headphones", name: "Headphones", input: false, output: true, builtIn: false)
    let microphone = AudioDevice(id: 3, uid: "mic", name: "Mic", input: true, output: false, builtIn: false)
    func testDefaultAndExplicitRoute() {
        XCTAssertEqual(AppRoute.output(for: nil, devices: [builtIn, headphones], defaultID: 1), builtIn)
        XCTAssertEqual(AppRoute.output(for: "headphones", devices: [builtIn, headphones], defaultID: 1), headphones)
    }
    func testUnavailableAndInputOnlyDoNotSilentlyFallBack() {
        XCTAssertNil(AppRoute.output(for: "unplugged", devices: [builtIn], defaultID: 1))
        XCTAssertNil(AppRoute.output(for: "mic", devices: [builtIn, microphone], defaultID: 1))
    }
    func testPerAppOutputAllowsVirtualDuplexButNotPhysicalDuplex() {
        let virtual = AudioDevice(id: 4, uid: "virtual", name: "Virtual", input: true, output: true, builtIn: false, transport: kAudioDeviceTransportTypeVirtual)
        let physical = AudioDevice(id: 5, uid: "physical", name: "Headset", input: true, output: true, builtIn: false, transport: kAudioDeviceTransportTypeBluetooth)
        XCTAssertTrue(AppOutputSupport.isSupported(builtIn))
        XCTAssertTrue(AppOutputSupport.isSupported(virtual))
        XCTAssertFalse(AppOutputSupport.isSupported(physical))
        XCTAssertFalse(AppOutputSupport.isSupported(microphone))
    }
    func testStoredMixClampsVolumeAndNormalizesEmptyRoute() throws {
        let data = Data("{\"volume\":3.0,\"muted\":true,\"outputUID\":\"\"}".utf8)
        let value = try JSONDecoder().decode(AppMix.self, from: data)
        XCTAssertEqual(value.volume, 1)
        XCTAssertNil(value.outputUID)
        XCTAssertTrue(value.muted)
    }
    func testOldSettingsDecodeWithoutRoute() throws {
        let value = try JSONDecoder().decode(AppMix.self, from: Data("{\"volume\":0.5,\"muted\":false}".utf8))
        XCTAssertNil(value.outputUID)
    }
}

final class SessionPolicyTests: XCTestCase {
    func testRebuildWhenProcessOrOutputChanges() {
        let current = SessionSignature(processes: [10], outputUID: "headphones")
        XCTAssertEqual(SessionPolicy.action(desired: true, candidate: current, current: current, failed: nil), .keep)
        XCTAssertEqual(SessionPolicy.action(desired: true, candidate: SessionSignature(processes: [11], outputUID: "headphones"), current: current, failed: nil), .start)
        XCTAssertEqual(SessionPolicy.action(desired: true, candidate: SessionSignature(processes: [10], outputUID: "mac"), current: current, failed: nil), .start)
    }
    func testRecreatedDeviceWithSameUIDRebuildsSessionAndRetryBudget() {
        let old = SessionSignature(processes: [10], outputUID: "headphones", outputID: 42)
        let replacement = SessionSignature(processes: [10], outputUID: "headphones", outputID: 99)
        XCTAssertEqual(SessionPolicy.action(desired: true, candidate: replacement, current: old, failed: nil), .start)
        var budget = SessionRetryBudget()
        XCTAssertTrue(budget.consume(for: old, desired: true))
        XCTAssertTrue(budget.consume(for: old, desired: true))
        XCTAssertFalse(budget.consume(for: old, desired: true))
        XCTAssertTrue(budget.consume(for: replacement, desired: true))
    }
    func testWaitForDeviceAndAvoidRepeatedFailure() {
        let signature = SessionSignature(processes: [10], outputUID: "mac")
        XCTAssertEqual(SessionPolicy.action(desired: true, candidate: nil, current: signature, failed: nil), .stop)
        XCTAssertEqual(SessionPolicy.action(desired: true, candidate: signature, current: nil, failed: signature), .wait)
        XCTAssertEqual(SessionPolicy.action(desired: false, candidate: signature, current: signature, failed: nil), .stop)
    }
}

final class StreamWatchdogTests: XCTestCase {
    func testStallRequiresElapsedTime() {
        var watchdog = StreamWatchdog()
        XCTAssertFalse(watchdog.poll(callbacks: 10, at: 1))
        XCTAssertFalse(watchdog.poll(callbacks: 10, at: 6.9))
        XCTAssertTrue(watchdog.poll(callbacks: 10, at: 7))
    }
    func testProgressResetsTimer() {
        var watchdog = StreamWatchdog()
        XCTAssertFalse(watchdog.poll(callbacks: 2, at: 1))
        XCTAssertFalse(watchdog.poll(callbacks: 3, at: 6))
        XCTAssertFalse(watchdog.poll(callbacks: 3, at: 11))
        XCTAssertTrue(watchdog.poll(callbacks: 3, at: 12))
    }
}

final class StreamHealthTests: XCTestCase {
    func testDuplexHealthIgnoresStartupButDetectsLaterLoss() {
        var health = DuplexStreamHealth(startedAt: 10)
        XCTAssertFalse(health.shouldStop(underruns: 6656, overruns: 0, at: 10.5))
        XCTAssertFalse(health.shouldStop(underruns: 6656, overruns: 0, at: 11.1))
        XCTAssertFalse(health.shouldStop(underruns: 7680, overruns: 0, at: 12))
        XCTAssertTrue(health.shouldStop(underruns: 7681, overruns: 0, at: 13))
    }
    func testRejectsPersistentBufferMismatchButAllowsInitialJitter() {
        XCTAssertFalse(StreamHealth.shouldStop(underruns: 4, overruns: 0))
        XCTAssertTrue(StreamHealth.shouldStop(underruns: 1025, overruns: 0))
        XCTAssertTrue(StreamHealth.shouldStop(underruns: 0, overruns: 1025))
    }
}

final class SessionRetryTests: XCTestCase {
    func testNewProcessOrOutputGetsFreshRetryBudget() {
        let first = SessionSignature(processes: [1], outputUID: "speakers")
        let second = SessionSignature(processes: [1], outputUID: "headset")
        let restarted = SessionSignature(processes: [2], outputUID: "headset")
        var budget = SessionRetryBudget()
        XCTAssertTrue(budget.consume(for: first, desired: true))
        XCTAssertTrue(budget.consume(for: first, desired: true))
        XCTAssertFalse(budget.consume(for: first, desired: true))
        XCTAssertTrue(budget.consume(for: second, desired: true))
        XCTAssertTrue(budget.consume(for: restarted, desired: true))
        XCTAssertFalse(budget.consume(for: restarted, desired: false))
    }
    func testRetriesAreBoundedAndOnlyForRequestedSession() {
        XCTAssertTrue(SessionRetryPolicy.allowed(attempts: 0, desired: true))
        XCTAssertTrue(SessionRetryPolicy.allowed(attempts: 1, desired: true))
        XCTAssertFalse(SessionRetryPolicy.allowed(attempts: 2, desired: true))
        XCTAssertFalse(SessionRetryPolicy.allowed(attempts: 0, desired: false))
    }
}

final class CommunicationPassthroughTests: XCTestCase {
    func testBypassesOnlyWhenNativeRouteAndUnchangedMixAreProven() {
        let output = AudioDevice(id: 42, uid: "speakers", name: "Speakers", input: false, output: true, builtIn: true)
        let app = ActiveApp(id: "call", name: "Call", processes: [10], inputActive: true, nativeOutputIDs: [42])
        XCTAssertTrue(CommunicationPassthroughPolicy.canBypass(app: app, mix: AppMix(), output: output))
        XCTAssertFalse(CommunicationPassthroughPolicy.canBypass(app: app, mix: AppMix(volume: 0.5), output: output))
        XCTAssertFalse(CommunicationPassthroughPolicy.canBypass(app: app, mix: AppMix(muted: true), output: output))
        XCTAssertFalse(CommunicationPassthroughPolicy.canBypass(app: ActiveApp(id: "call", name: "Call", processes: [10], inputActive: true, nativeOutputIDs: [7]), mix: AppMix(), output: output))
        XCTAssertFalse(CommunicationPassthroughPolicy.canBypass(app: ActiveApp(id: "call", name: "Call", processes: [10], inputActive: true, nativeOutputIDs: nil), mix: AppMix(), output: output))
        XCTAssertFalse(CommunicationPassthroughPolicy.canBypass(app: ActiveApp(id: "music", name: "Music", processes: [10], inputActive: false, nativeOutputIDs: [42]), mix: AppMix(), output: output))
    }
}
