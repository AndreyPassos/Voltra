import Foundation

/// Processa o ciclo de vida do áudio fora da interface, preservando a ordem por aplicativo.
final class AudioWorker {
    private let queue = DispatchQueue(label: "com.voltra.audio.lifecycle.\(UUID().uuidString)", qos: .userInitiated)
    func run<T>(_ work: @escaping () throws -> T, shouldStart: @escaping () -> Bool = { true }, discard: @escaping (T) -> Void = { _ in }, timeout: TimeInterval? = nil, onTimeout: @escaping () -> Void = {}, completion: @escaping (Result<T, Error>) -> Bool) {
        var finished = false // Accessed only on the main queue after scheduling.
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !finished { onTimeout() }
            }
        }
        queue.async {
            let allowed = DispatchQueue.main.sync {
                guard shouldStart() else { finished = true; return false }
                return true
            }
            guard allowed else { return }
            let result = Result { try work() }
            let accepted = DispatchQueue.main.sync { finished = true; return completion(result) }
            if !accepted, case let .success(value) = result { discard(value) }
        }
    }
    func dispose(_ work: @escaping () -> Void) { queue.async(execute: work) }
}
