import XCTest
@testable import Voltra
final class DevicePolicyTests: XCTestCase {
    let internalDevice = AudioDevice(id: 1, uid: "internal", name: "Mac", input: true, output: true, builtIn: true)
    let headset = AudioDevice(id: 2, uid: "headset", name: "Headset", input: true, output: true, builtIn: false)
    func testPreferredAndReconnect() {
        XCTAssertEqual(DevicePolicy.target(devices: [internalDevice, headset], preferred: "headset", automatic: true, input: true), headset)
        XCTAssertEqual(DevicePolicy.target(devices: [internalDevice], preferred: "headset", automatic: true, input: false), internalDevice)
        XCTAssertEqual(DevicePolicy.target(devices: [internalDevice, headset], preferred: "headset", automatic: true, input: false), headset)
    }
    func testDisabledAndMissingFallback() {
        XCTAssertNil(DevicePolicy.target(devices: [headset], preferred: "headset", automatic: false, input: false))
        XCTAssertNil(DevicePolicy.target(devices: [], preferred: "headset", automatic: true, input: true))
        XCTAssertNil(DevicePolicy.target(devices: [internalDevice], preferred: "", automatic: true, input: true))
    }
    func testIndependentPreferredDevicesRestoreAfterReconnect() {
        let mic = AudioDevice(id: 4, uid: "headset-mic", name: "Headset", input: true, output: false, builtIn: false)
        let speakers = AudioDevice(id: 5, uid: "headset-out", name: "Headset", input: false, output: true, builtIn: false)
        let preferences = DevicePreferences(inputUID: mic.uid, outputUID: speakers.uid, automatic: true)
        XCTAssertEqual(preferences.target(devices: [internalDevice, mic, speakers], input: true), mic)
        XCTAssertEqual(preferences.target(devices: [internalDevice], input: false), internalDevice)
        XCTAssertEqual(preferences.target(devices: [internalDevice, mic, speakers], input: false), speakers)
    }
    func testPreferencesPersistIndependently() {
        let suite = "VoltraTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DevicePreferences(inputUID: "mic", outputUID: "output", automatic: true).save(to: defaults)
        XCTAssertEqual(DevicePreferences.load(from: defaults), DevicePreferences(inputUID: "mic", outputUID: "output", automatic: true))
    }
    func testKeepsCurrentInternalFallbackWhenDeviceOrderChanges() {
        let first = AudioDevice(id: 10, uid: "internal-a", name: "First", input: false, output: true, builtIn: true)
        let current = AudioDevice(id: 11, uid: "internal-b", name: "Current", input: false, output: true, builtIn: true)
        XCTAssertEqual(DevicePolicy.target(devices: [first, current], preferred: "headset", automatic: true, input: false, currentID: current.id), current)
        XCTAssertEqual(DevicePolicy.target(devices: [current, first], preferred: "headset", automatic: true, input: false, currentID: current.id), current)
        let headset = AudioDevice(id: 12, uid: "headset", name: "Headset", input: false, output: true, builtIn: false)
        XCTAssertEqual(DevicePolicy.target(devices: [first, current, headset], preferred: "headset", automatic: true, input: false, currentID: current.id), headset)
    }
    func testCapability() {
        let outputOnly = AudioDevice(id: 3, uid: "output", name: "Output", input: false, output: true, builtIn: false)
        XCTAssertEqual(DevicePolicy.target(devices: [outputOnly, internalDevice], preferred: "output", automatic: true, input: true), internalDevice)
        XCTAssertEqual(DevicePolicy.target(devices: [outputOnly, internalDevice], preferred: "output", automatic: true, input: false), outputOnly)
    }
}
