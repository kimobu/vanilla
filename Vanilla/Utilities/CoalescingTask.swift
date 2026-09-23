//
//  CoalescingTask.swift
//  Ice
//

/// Runs one operation at a time, keeping only the latest request received while busy.
@MainActor
final class CoalescingTask {
    typealias Operation = @MainActor @Sendable () async -> Void

    private var pending: Operation?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    isolated deinit {
        worker?.cancel()
    }

    func schedule(_ operation: @escaping Operation) {
        pending = operation
        guard worker == nil else { return }
        generation &+= 1
        let generation = generation
        worker = Task { [weak self] in
            // Do not retain the coordinator across an operation's suspension.
            while !Task.isCancelled, let operation = self?.takePending(generation: generation) {
                await operation()
            }
            self?.finish(generation: generation)
        }
    }

    func cancel() {
        generation &+= 1
        pending = nil
        worker?.cancel()
        worker = nil
    }

    private func takePending(generation: UInt64) -> Operation? {
        guard self.generation == generation else { return nil }
        defer { pending = nil }
        return pending
    }

    private func finish(generation: UInt64) {
        guard self.generation == generation else { return }
        worker = nil
    }
}
