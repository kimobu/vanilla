//
//  DelayedAction.swift
//  Ice
//

/// Keeps one delayed action, preserving its deadline while the request stays the same.
@MainActor
final class DelayedAction<Key: Equatable> {
    typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void

    private let sleep: Sleep
    private var key: Key?
    private var delay: Duration?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    isolated deinit {
        task?.cancel()
    }

    func schedule(key: Key, after delay: Duration, action: @MainActor @escaping () -> Void) {
        guard task == nil || self.key != key || self.delay != delay else { return }
        cancel()
        self.key = key
        self.delay = delay
        let generation = generation
        task = Task { [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                _ = self?.finish(generation: generation)
                return
            }
            // A suspended operation may ignore cancellation. It must not run
            // its action or clear a newer request when it eventually returns.
            guard !Task.isCancelled, self?.finish(generation: generation) == true else { return }
            action()
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        key = nil
        delay = nil
    }

    private func finish(generation: UInt64) -> Bool {
        guard self.generation == generation else { return false }
        task = nil
        key = nil
        delay = nil
        return true
    }
}
