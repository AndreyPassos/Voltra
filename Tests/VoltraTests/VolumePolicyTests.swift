import XCTest
@testable import Voltra
final class VolumePolicyTests: XCTestCase {
    func testPrefersMasterAndFallsBackToChannels() {
        XCTAssertEqual(VolumePolicy.elements(masterSettable: true, channelElements: [1, 2]), [0])
        XCTAssertEqual(VolumePolicy.elements(masterSettable: false, channelElements: [1, 2]), [1, 2])
        XCTAssertEqual(VolumePolicy.elements(masterSettable: false, channelElements: []), [])
    }
    func testScalingPreservesChannelBalance() {
        let result = VolumePolicy.scaled([0.8, 0.4], target: 0.4)
        XCTAssertEqual(result[0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(result[1], 0.2, accuracy: 0.0001)
        XCTAssertEqual(VolumePolicy.scaled([0, 0], target: 0.5), [0.5, 0.5])
        XCTAssertEqual(VolumePolicy.scaled([0, 0], target: 0.5, fallback: [1, 0.5]), [0.5, 0.25])
        XCTAssertEqual(VolumePolicy.scaled([0.8], target: 2), [1])
    }
}
