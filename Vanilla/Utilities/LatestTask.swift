//
//  LatestTask.swift
//  Ice
//

/// Shares identical in-flight work and prevents superseded work from publishing a result.
@MainActor
final class LatestTask<Key: Equatable, Value: Sendable> {
    private var generation: UInt64 = 0
    private var running: (key: Key, generation: UInt64, task: Task<Value, Never>)?

    isolated deinit {
        running?.task.cancel()
    }

    func value(for key: Key, operation: @Sendable @escaping () async -> Value) async -> Value? {
        let job: (key: Key, generation: UInt64, task: Task<Value, Never>)
        if let running, running.key == key {
            job = running
        } else {
            cancel()
            job = (key, generation, Task(operation: operation))
            running = job
        }

        let value = await job.task.value
        guard generation == job.generation else { return nil }
        if running?.generation == job.generation {
            running = nil
        }
        // A cancelled waiter must still retire completed shared work. Otherwise
        // the next panel opening can reuse old images instead of capturing again.
        guard !Task.isCancelled else { return nil }
        return value
    }

    /// Waits for existing work, including its cleanup, without starting another request.
    func waitForCompletion() async {
        _ = await running?.task.value
    }

    func cancel() {
        generation &+= 1
        running?.task.cancel()
        running = nil
    }
}
