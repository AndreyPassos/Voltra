import XCTest
import AVFoundation

/// Offline feasibility check; this does not validate real-time behavior or the Voltra render path.
final class SampleRateExplorationTests: XCTestCase {
    func testKnownToneSurvivesSampleRateConversionBothWays() throws {
        for (sourceRate, targetRate) in [(44100.0, 48000.0), (48000.0, 44100.0)] {
            let sourceFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2))
            let targetFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 2))
            let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(sourceRate)))
            source.frameLength = source.frameCapacity
            let channels = try XCTUnwrap(source.floatChannelData)
            for frame in 0..<Int(source.frameLength) {
                let sample = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / sourceRate))
                channels[0][frame] = sample
                channels[1][frame] = sample
            }
            let converter = try XCTUnwrap(AVAudioConverter(from: sourceFormat, to: targetFormat))
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(targetRate) + 2048))
            var provided = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if provided { inputStatus.pointee = .endOfStream; return nil }
                provided = true
                inputStatus.pointee = .haveData
                return source
            }
            XCTAssertNil(error)
            XCTAssertNotEqual(status, .error)
            XCTAssertEqual(Double(output.frameLength), targetRate, accuracy: 2)
            let samples = try XCTUnwrap(output.floatChannelData)
            let count = Int(output.frameLength)
            let start = 256, end = count - 256
            guard end > start else { XCTFail("Saída insuficiente"); continue }
            var crossings = 0
            var energy = 0.0
            var channelDifference = 0.0
            for i in start..<end {
                let sample = Double(samples[0][i])
                energy += sample * sample
                channelDifference = max(channelDifference, abs(sample - Double(samples[1][i])))
                if i > start && samples[0][i-1] <= 0 && samples[0][i] > 0 { crossings += 1 }
            }
            let frequency = Double(crossings) * targetRate / Double(end - start)
            let rms = sqrt(energy / Double(end - start))
            print("VOLTRA_OFFLINE_CONVERSION \(Int(sourceRate))->\(Int(targetRate)) frames=\(count) frequency=\(frequency) rms=\(rms)")
            XCTAssertEqual(frequency, 440, accuracy: 2)
            XCTAssertEqual(rms, 0.5 / sqrt(2), accuracy: 0.01)
            XCTAssertLessThan(channelDifference, 0.0001)
        }
    }
}
