//
//  DelayedActionTests.swift
//  Ice
//

import Testing

@MainActor
struct DelayedActionTests {
    @MainActor
    private final class Sleeper {
        var waits = [CheckedContinuation<Void, any Error>]()
        var durations = [Duration]()
        var returned = 0
        var cancellations = [Bool]()

        func sleep(for duration: Duration) async throws {
            durations.append(duration)
            defer {
                cancellations.append(Task.isCancelled)
                returned += 1
            }
            try await withCheckedThrowingContinuation { waits.append($0) }
        }

        func waitForStarts(_ count: Int) async {
            while waits.count < count { await Task.yield() }
        }

        func waitForReturns(_ count: Int) async {
            while returned < count { await Task.yield() }
        }
    }

    @Test(.timeLimit(.minutes(1))) func repeatedHoverKeepsOriginalDeadline() async {
        let sleeper = Sleeper()
        let action = DelayedAction<Bool>(sleep: sleeper.sleep)
        var calls = [Bool]()
        action.schedule(key: true, after: .seconds(1)) { calls.append(true) }
        await sleeper.waitForStarts(1)
        for _ in 0..<100 {
            action.schedule(key: true, after: .seconds(1)) { calls.append(false) }
        }
        sleeper.waits[0].resume()
        await sleeper.waitForReturns(1)
        #expect(sleeper.durations == [.seconds(1)])
        #expect(calls == [true])
    }

    @Test(.timeLimit(.minutes(1))) func supersededWaitCannotRunOrClearNewAction() async {
        let sleeper = Sleeper()
        let action = DelayedAction<Bool>(sleep: sleeper.sleep)
        var calls = [Bool]()
        action.schedule(key: true, after: .seconds(1)) { calls.append(true) }
        await sleeper.waitForStarts(1)
        action.schedule(key: false, after: .seconds(1)) { calls.append(false) }
        await sleeper.waitForStarts(2)
        // This sleeper deliberately returns normally even after cancellation.
        sleeper.waits[0].resume()
        await sleeper.waitForReturns(1)
        action.schedule(key: false, after: .seconds(1)) { calls.append(true) }
        sleeper.waits[1].resume()
        await sleeper.waitForReturns(2)
        #expect(sleeper.durations.count == 2)
        #expect(sleeper.cancellations == [true, false])
        #expect(calls == [false])
    }

    @Test(.timeLimit(.minutes(1))) func stoppingThenRestartingDiscardsOldAction() async {
        let sleeper = Sleeper()
        let action = DelayedAction<Bool>(sleep: sleeper.sleep)
        var calls = [Int]()
        action.schedule(key: true, after: .seconds(1)) { calls.append(1) }
        await sleeper.waitForStarts(1)
        action.cancel()
        action.schedule(key: true, after: .seconds(1)) { calls.append(2) }
        await sleeper.waitForStarts(2)
        sleeper.waits[1].resume()
        await sleeper.waitForReturns(1)
        sleeper.waits[0].resume()
        await sleeper.waitForReturns(2)
        #expect(calls == [2])
        #expect(sleeper.cancellations == [false, true])
    }

    @Test(.timeLimit(.minutes(1))) func releasingOwnerCancelsWaitAndDiscardsAction() async {
        let sleeper = Sleeper()
        var action: DelayedAction<Bool>? = DelayedAction(sleep: sleeper.sleep)
        weak let weakAction = action
        var called = false
        action?.schedule(key: true, after: .seconds(1)) { called = true }
        await sleeper.waitForStarts(1)
        action = nil
        #expect(weakAction == nil)
        sleeper.waits[0].resume()
        await sleeper.waitForReturns(1)
        #expect(!called)
        #expect(sleeper.cancellations == [true])
    }

    @Test(.timeLimit(.minutes(1))) func changingDelayReplacesWaitAndThrownWaitAllowsRetry() async {
        let sleeper = Sleeper()
        let action = DelayedAction<Bool>(sleep: sleeper.sleep)
        var calls = [Int]()
        action.schedule(key: true, after: .seconds(1)) { calls.append(1) }
        await sleeper.waitForStarts(1)
        action.schedule(key: true, after: .seconds(2)) { calls.append(2) }
        await sleeper.waitForStarts(2)
        sleeper.waits[0].resume(throwing: CancellationError())
        sleeper.waits[1].resume(throwing: CancellationError())
        await sleeper.waitForReturns(2)
        action.schedule(key: true, after: .seconds(2)) { calls.append(3) }
        await sleeper.waitForStarts(3)
        sleeper.waits[2].resume()
        await sleeper.waitForReturns(3)
        #expect(sleeper.durations == [.seconds(1), .seconds(2), .seconds(2)])
        #expect(calls == [3])
    }
}
