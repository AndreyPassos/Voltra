import XCTest
import AudioDSP
import AudioToolbox
@testable import Voltra
final class AudioDSPTests: XCTestCase {
    func testStereoToMonoAveragesChannelsAndRespectsMute() {
        let state = vdsp_create()!
        defer { vdsp_destroy(state) }
        let input: [Float] = [1, 0.5, -1, 0.5]
        var output: [Float] = [9, 9]
        vdsp_set_gain(state, 0.5, false)
        input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in vdsp_stereo_to_mono(state, i.baseAddress, 2, o.baseAddress, 2) } }
        XCTAssertEqual(output[0], 0.375, accuracy: 0.0001)
        XCTAssertEqual(output[1], -0.125, accuracy: 0.0001)
        vdsp_set_gain(state, 0.5, true)
        input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in vdsp_stereo_to_mono(state, i.baseAddress, 2, o.baseAddress, 2) } }
        XCTAssertEqual(output, [0, 0])
    }
    func testGainMuteAndRemainingOutput() {
        let state = vdsp_create()!
        defer { vdsp_destroy(state) }
        var input: [Float] = [1, -1, 0.5, -0.5]
        var output: [Float] = [9, 9, 9, 9, 9, 9]
        vdsp_set_gain(state, 0.5, false)
        input.withUnsafeMutableBufferPointer { i in output.withUnsafeMutableBufferPointer { o in vdsp_process(state, i.baseAddress, UInt32(i.count), o.baseAddress, UInt32(o.count)) } }
        XCTAssertEqual(output, [0.5, -0.5, 0.25, -0.25, 0, 0])
        vdsp_set_gain(state, 0.5, true)
        input.withUnsafeMutableBufferPointer { i in output.withUnsafeMutableBufferPointer { o in vdsp_process(state, i.baseAddress, UInt32(i.count), o.baseAddress, UInt32(o.count)) } }
        XCTAssertEqual(output, [0, 0, 0, 0, 0, 0])
    }
    func testStereoTransportWrapsAndPreservesFrameOrder() {
        let ring = vaudio_ring_create(3)!
        defer { vaudio_ring_destroy(ring) }
        let first: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(first.withUnsafeBufferPointer { vaudio_ring_write(ring, $0.baseAddress, 3) }, 3)
        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { vaudio_ring_read(ring, $0.baseAddress, 2) }, 2)
        XCTAssertEqual(output, [1, 2, 3, 4])
        let second: [Float] = [7, 8, 9, 10, 11, 12]
        XCTAssertEqual(second.withUnsafeBufferPointer { vaudio_ring_write(ring, $0.baseAddress, 3) }, 2)
        output = [Float](repeating: 9, count: 8)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { vaudio_ring_read(ring, $0.baseAddress, 4) }, 3)
        XCTAssertEqual(output, [5, 6, 7, 8, 9, 10, 0, 0])
    }

    func testDuplexFormatRejectsIncompatibleStreamAndRates() {
        let good = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        XCTAssertTrue(DuplexFormatPolicy.supports(good, outputRate: 48000))
        XCTAssertFalse(DuplexFormatPolicy.supports(good, outputRate: 44100))
        var planar = good; planar.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        XCTAssertFalse(DuplexFormatPolicy.supports(planar, outputRate: 48000))
        var bigEndian = good; bigEndian.mFormatFlags |= kAudioFormatFlagIsBigEndian
        XCTAssertFalse(DuplexFormatPolicy.supports(bigEndian, outputRate: 48000))
        var mono = good; mono.mChannelsPerFrame = 1
        XCTAssertFalse(DuplexFormatPolicy.supports(mono, outputRate: 48000))
    }
    func testDuplexBridgeUsesCaptureRateEvenWhenOutputRateDiffers() {
        let tap = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var capture = tap; capture.mSampleRate = 44100
        XCTAssertEqual(DuplexFormatPolicy.clientRate(tap: tap, capture: capture, outputRate: 48000), 44100)
        XCTAssertNil(DuplexFormatPolicy.clientRate(tap: tap, capture: capture, outputRate: .infinity))
        capture.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        XCTAssertNil(DuplexFormatPolicy.clientRate(tap: tap, capture: capture, outputRate: 48000))
    }
    func testOutputStreamListDistinguishesUnavailableFromMultipleStreams() {
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        XCTAssertEqual(OutputStreamListPolicy.classify(bytes: 0), .unavailable)
        XCTAssertEqual(OutputStreamListPolicy.classify(bytes: size), .supported)
        XCTAssertEqual(OutputStreamListPolicy.classify(bytes: size * 2), .multiple)
        XCTAssertEqual(OutputStreamListPolicy.classify(bytes: size + 1), .invalid)
    }
    func testStandardFormatRejectsUnsafePCMLayoutsAndInvalidRates() {
        let stereo = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var mono = stereo; mono.mChannelsPerFrame = 1; mono.mBytesPerFrame = 4; mono.mBytesPerPacket = 4
        XCTAssertTrue(StandardFormatPolicy.supports(input: stereo, output: stereo))
        XCTAssertTrue(StandardFormatPolicy.supports(input: stereo, output: mono))
        var bad = stereo; bad.mFormatFlags |= kAudioFormatFlagIsBigEndian
        XCTAssertFalse(StandardFormatPolicy.supports(input: bad, output: stereo))
        XCTAssertFalse(StandardFormatPolicy.supports(input: stereo, output: bad))
        bad = stereo; bad.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        XCTAssertFalse(StandardFormatPolicy.supports(input: bad, output: stereo))
        bad = stereo; bad.mFramesPerPacket = 2
        XCTAssertFalse(StandardFormatPolicy.supports(input: stereo, output: bad))
        bad = stereo; bad.mSampleRate = .infinity
        XCTAssertFalse(StandardFormatPolicy.supports(input: stereo, output: bad))
    }
    func testStandardFormatRejectsDifferentSampleRatesUntilConversionExists() {
        let input = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var output = input; output.mSampleRate = 44100
        XCTAssertFalse(StandardFormatPolicy.supports(input: input, output: output))
        XCTAssertFalse(StandardFormatPolicy.supports(input: output, output: input))
        output.mSampleRate = input.mSampleRate
        XCTAssertTrue(StandardFormatPolicy.supports(input: input, output: output))
    }
    func testStereoTransportReportsBufferedFramesAcrossWritesAndReads() {
        let ring = vaudio_ring_create(4)!
        defer { vaudio_ring_destroy(ring) }
        XCTAssertEqual(vaudio_ring_available(ring), 0)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(input.withUnsafeBufferPointer { vaudio_ring_write(ring, $0.baseAddress, 3) }, 3)
        XCTAssertEqual(vaudio_ring_available(ring), 3)
        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { vaudio_ring_read(ring, $0.baseAddress, 2) }, 2)
        XCTAssertEqual(vaudio_ring_available(ring), 1)
    }
    func testStereoTransportCountsDroppedAndMissingFrames() {
        let ring = vaudio_ring_create(2)!
        defer { vaudio_ring_destroy(ring) }
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(input.withUnsafeBufferPointer { vaudio_ring_write(ring, $0.baseAddress, 3) }, 2)
        var output = [Float](repeating: 1, count: 6)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { vaudio_ring_read(ring, $0.baseAddress, 3) }, 2)
        XCTAssertEqual(vaudio_ring_overruns(ring), 1)
        XCTAssertEqual(vaudio_ring_underruns(ring), 1)
        XCTAssertEqual(output, [1, 2, 3, 4, 0, 0])
    }
    func testStereoTransportPreservesFramesAcrossConcurrentCallbacks() {
        let ring = vaudio_ring_create(127)!
        defer { vaudio_ring_destroy(ring) }
        let count = 10000
        var received = [Float](repeating: -1, count: count * 2)
        DispatchQueue.concurrentPerform(iterations: 2) { role in
            if role == 0 {
                for index in 0..<count {
                    let frame: [Float] = [Float(index), -Float(index)]
                    while frame.withUnsafeBufferPointer({ vaudio_ring_write(ring, $0.baseAddress, 1) }) == 0 { Thread.sleep(forTimeInterval: 0.00001) }
                }
            } else {
                var frame: [Float] = [0, 0]
                for index in 0..<count {
                    while frame.withUnsafeMutableBufferPointer({ vaudio_ring_read(ring, $0.baseAddress, 1) }) == 0 { Thread.sleep(forTimeInterval: 0.00001) }
                    received[index * 2] = frame[0]
                    received[index * 2 + 1] = frame[1]
                }
            }
        }
        for index in 0..<count {
            XCTAssertEqual(received[index * 2], Float(index))
            XCTAssertEqual(received[index * 2 + 1], -Float(index))
        }
    }

}
