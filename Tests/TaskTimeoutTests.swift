//
//  TaskTimeoutTests.swift
//  Ice
//

import Foundation
import Synchronization
import Testing

struct TaskTimeoutTests {
    /// Holds one wait at a known point, with synchronous cancellation delivery.
    private final class Gate: Sendable {
        private struct State {
            var started = false
            var cancelled = false
            var result: Result<Void, any Error>?
            var continuation: CheckedContinuation<Void, any Error>?
        }

        private let state = Mutex(State())

        var wasCancelled: Bool { state.withLock { $0.cancelled } }

        func waitUntilStarted() async {
            while !state.withLock({ $0.started }) { await Task.yield() }
        }

        func wait() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let result = state.withLock { state in
                        state.started = true
                        if state.result == nil { state.continuation = continuation }
                        return state.result
                    }
                    if let result { continuation.resume(with: result) }
                }
            } onCancel: {
                self.finish(.failure(CancellationError()), cancelled: true)
            }
        }

        func open() { finish(.success(())) }

        private func finish(_ result: Result<Void, any Error>, cancelled: Bool = false) {
            let continuation = state.withLock { state in
                state.cancelled = state.cancelled || cancelled
                guard state.result == nil else { return nil as CheckedContinuation<Void, any Error>? }
                state.result = result
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(with: result)
        }
    }

    /// Delays the clock's wait until the test releases it. It never fires early.
    private struct GatedClock: Clock {
        let gate = Gate()
        var now: ContinuousClock.Instant { .now }
        var minimumResolution: Duration { .nanoseconds(1) }

        func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
            try await gate.wait()
            try await ContinuousClock().sleep(until: deadline, tolerance: tolerance)
        }
    }

    private enum OperationError: Error { case expected }

    @Test(.timeLimit(.minutes(1))) func alreadyCancelledCallerDoesNotStartWork() async {
        let called = Mutex(false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Task<Int, any Error>.run(
                operation: {
                    called.withLock { $0 = true }
                    return 42
                },
                withTimeout: .seconds(60),
                tolerance: nil,
                clock: ContinuousClock()
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!called.withLock { $0 })
    }

    @Test(.timeLimit(.minutes(1))) func successCancelsTheDeadlineWait() async throws {
        let clock = GatedClock()
        let result = try await Task<Int, any Error>.run(
            operation: {
                await clock.gate.waitUntilStarted()
                return 42
            },
            withTimeout: .seconds(60),
            tolerance: nil,
            clock: clock
        )
        #expect(result == 42)
        #expect(clock.gate.wasCancelled)
    }

    @Test(.timeLimit(.minutes(1))) func operationErrorCancelsTheDeadlineWait() async {
        let clock = GatedClock()
        await #expect(throws: OperationError.expected) {
            try await Task<Int, any Error>.run(
                operation: {
                    await clock.gate.waitUntilStarted()
                    throw OperationError.expected
                },
                withTimeout: .seconds(60),
                tolerance: nil,
                clock: clock
            )
        }
        #expect(clock.gate.wasCancelled)
    }

    @Test(.timeLimit(.minutes(1))) func timeoutWaitsForOperationCleanup() async {
        let clock = GatedClock()
        let operation = Gate()
        let cleanedUp = Mutex(false)
        let task = Task {
            try await Task<Int, any Error>.run(
                operation: {
                    defer { cleanedUp.withLock { $0 = true } }
                    try await operation.wait()
                    return 42
                },
                withTimeout: .zero,
                tolerance: nil,
                clock: clock
            )
        }
        await operation.waitUntilStarted()
        await clock.gate.waitUntilStarted()
        clock.gate.open()
        await #expect(throws: TaskTimeoutError.self) { try await task.value }
        #expect(operation.wasCancelled)
        #expect(cleanedUp.withLock { $0 })
    }

    @Test(.timeLimit(.minutes(1))) func callerCancellationStopsBothChildren() async {
        let clock = GatedClock()
        let operation = Gate()
        let task = Task {
            try await Task<Int, any Error>.run(
                operation: {
                    try await operation.wait()
                    return 42
                },
                withTimeout: .seconds(60),
                tolerance: nil,
                clock: clock
            )
        }
        await operation.waitUntilStarted()
        await clock.gate.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(operation.wasCancelled)
        #expect(clock.gate.wasCancelled)
    }
}
