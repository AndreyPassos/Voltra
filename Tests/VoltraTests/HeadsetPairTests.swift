import XCTest
import CoreAudio
@testable import Voltra
final class HeadsetPairTests: XCTestCase {
    func testPairsUniqueBluetoothEndpoints() {
        let output = AudioDevice(id: 1, uid: "id-a:output", name: "Headset", input: false, output: true, builtIn: false, transport: kAudioDeviceTransportTypeBluetooth)
        let input = AudioDevice(id: 2, uid: "id-a:input", name: "Headset", input: true, output: false, builtIn: false, transport: kAudioDeviceTransportTypeBluetooth)
        XCTAssertEqual(HeadsetPair.inputUID(for: output, devices: [output, input]), "id-a:input")
    }
    func testAvoidsAmbiguousOrNonBluetoothMatches() {
        let output = AudioDevice(id: 1, uid: "id-a:output", name: "Headset", input: false, output: true, builtIn: false, transport: kAudioDeviceTransportTypeBluetooth)
        let one = AudioDevice(id: 2, uid: "id-a:input", name: "Headset", input: true, output: false, builtIn: false, transport: kAudioDeviceTransportTypeBluetooth)
        let two = AudioDevice(id: 3, uid: "id-a:input", name: "Headset", input: true, output: false, builtIn: false, transport: kAudioDeviceTransportTypeBluetooth)
        let usb = AudioDevice(id: 4, uid: "id-a:input", name: "Headset", input: true, output: false, builtIn: false, transport: kAudioDeviceTransportTypeUSB)
        XCTAssertNil(HeadsetPair.inputUID(for: output, devices: [output, one, two]))
        XCTAssertNil(HeadsetPair.inputUID(for: output, devices: [output, usb]))
    }
    func testIdenticalNamesWithDifferentBluetoothIdentitiesAreNotPaired() {
        let output = AudioDevice(id: 1, uid: "unit-a:output", name: "Headset", input: false, output: true, builtIn: false, transport: kAudioDeviceTransportTypeBluetooth)
        let unrelated = AudioDevice(id: 2, uid: "unit-b:input", name: "Headset", input: true, output: false, builtIn: false, transport: kAudioDeviceTransportTypeBluetooth)
        XCTAssertNil(HeadsetPair.inputUID(for: output, devices: [output, unrelated]))
    }
}
