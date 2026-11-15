import Foundation

enum VolumePolicy {
    static func elements(masterSettable: Bool, channelElements: [UInt32]) -> [UInt32] {
        masterSettable ? [0] : channelElements
    }
    static func scaled(_ current: [Float], target: Float, fallback: [Float] = []) -> [Float] {
        let clamped = target.isFinite ? min(1, max(0, target)) : 0
        let source = (current.max() ?? 0) > 0 ? current : (fallback.count == current.count ? fallback : current)
        guard let maximum = source.max(), maximum > 0 else { return current.map { _ in clamped } }
        return source.map { min(1, max(0, $0 / maximum * clamped)) }
    }
}
