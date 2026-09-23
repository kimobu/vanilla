//
//  CoalescingTaskTests.swift
//  Ice
//

import Testing

@MainActor
struct CoalescingTaskTests {
    @MainActor
    private final class Work {
        var calls = [Int]()
        var continuation: CheckedContinuation<Void, Never>?
        var wasCancelled = false
        var finished = false

        func suspend(_ value: Int) async {
            calls.append(value)
            await withCheckedContinuation { continuation = $0 }
            wasCancelled = Task.isCancelled
            finished = true
        }

        func waitUntilStarted() async {
            while continuation == nil { await Task.yield() }
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test(.timeLimit(.minutes(1))) func burstsRunTheLatestRequestAfterCurrentWork() async {
        let queue = CoalescingTask()
        let work = Work()
        queue.schedule { await work.suspend(1) }
        await work.waitUntilStarted()
        queue.schedule { work.calls.append(2) }
        queue.schedule { work.calls.append(3) }
        #expect(work.calls == [1])
        work.finish()
        while work.calls.count < 2 { await Task.yield() }
        #expect(work.calls == [1, 3])
    }

    @Test(.timeLimit(.minutes(1))) func cancelledWorkerCannotConsumeNewRequests() async {
        let queue = CoalescingTask()
        let old = Work()
        let new = Work()
        queue.schedule { await old.suspend(1) }
        await old.waitUntilStarted()
        queue.schedule { old.calls.append(2) }
        queue.cancel()
        queue.schedule { await new.suspend(3) }
        await new.waitUntilStarted()
        old.finish()
        while !old.finished { await Task.yield() }
        queue.schedule { new.calls.append(4) }
        new.finish()
        while new.calls.count < 2 { await Task.yield() }
        #expect(old.calls == [1])
        #expect(old.wasCancelled)
        #expect(new.calls == [3, 4])
        #expect(!new.wasCancelled)
    }

    @Test(.timeLimit(.minutes(1))) func releasingTheOwnerCancelsSuspendedWork() async {
        var queue: CoalescingTask? = CoalescingTask()
        weak var weakQueue = queue
        let work = Work()
        queue?.schedule { await work.suspend(1) }
        await work.waitUntilStarted()
        queue = nil
        #expect(weakQueue == nil)
        work.finish()
        while !work.finished { await Task.yield() }
        #expect(work.wasCancelled)
    }
}
