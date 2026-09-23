//
//  LatestTaskTests.swift
//  Ice
//

import CoreGraphics
import Testing

@MainActor
struct LatestTaskTests {
    @MainActor
    private final class Work {
        private var continuation: CheckedContinuation<Int, Never>?
        private(set) var started = false
        private(set) var callCount = 0

        func run() async -> Int {
            callCount += 1
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                started = true
            }
        }

        func finish(_ value: Int) {
            continuation?.resume(returning: value)
            continuation = nil
        }

        func waitUntilStarted() async {
            while !started {
                await Task.yield()
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func supersededWorkCannotPublishEvenIfItIgnoresCancellation() async {
        let latest = LatestTask<Int, Int>()
        let work = Work()
        let old = Task { await latest.value(for: 1) { await work.run() } }
        await work.waitUntilStarted()
        let newest = await latest.value(for: 2) { 42 }
        work.finish(7)
        #expect(newest == 42)
        #expect(await old.value == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        CaptureDisplayGeometry(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1),
        CaptureDisplayGeometry(id: 1, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 2),
    ])
    func displayChangeDiscardsCaptureWithUnchangedItemCoordinates(newDisplay: CaptureDisplayGeometry) async {
        let latest = LatestTask<CaptureDisplayGeometry, Int>()
        let oldDisplay = CaptureDisplayGeometry(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2)
        let work = Work()
        let old = Task { await latest.value(for: oldDisplay) { await work.run() } }
        await work.waitUntilStarted()
        let newest = await latest.value(for: newDisplay) { 42 }
        work.finish(7)
        #expect(newest == 42)
        #expect(await old.value == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancelDiscardsPendingResult() async {
        let latest = LatestTask<Int, Int>()
        let work = Work()
        let pending = Task { await latest.value(for: 1) { await work.run() } }
        await work.waitUntilStarted()
        latest.cancel()
        work.finish(7)
        #expect(await pending.value == nil)
        #expect(await latest.value(for: 1) { 8 } == 8)
    }

    @Test(.timeLimit(.minutes(1))) func identicalConcurrentRequestsShareWork() async {
        let latest = LatestTask<Int, Int>()
        let work = Work()
        let first = Task { await latest.value(for: 1) { await work.run() } }
        await work.waitUntilStarted()
        let second = Task { await latest.value(for: 1) { await work.run() } }
        // Queue completion behind the second request on the same serial actor.
        let finish = Task { work.finish(9) }
        await finish.value
        #expect(await first.value == 9)
        #expect(await second.value == 9)
        #expect(work.callCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledWaiterRetiresCompletedWorkBeforeNextRequest() async {
        let latest = LatestTask<Int, Int>()
        let work = Work()
        let pending = Task { await latest.value(for: 1) { await work.run() } }
        await work.waitUntilStarted()
        pending.cancel()
        work.finish(7)
        #expect(await pending.value == nil)
        // The same key must start a fresh capture, not reuse the completed 7.
        #expect(await latest.value(for: 1) { 42 } == 42)
    }

    @Test(.timeLimit(.minutes(1))) func activationWaitsForSharedCaptureAfterPanelDismissal() async {
        let latest = LatestTask<Int, Int>()
        let work = Work()
        let capture = Task { await latest.value(for: 1) { await work.run() } }
        await work.waitUntilStarted()
        capture.cancel()
        var activated = false
        let activation = Task {
            await latest.waitForCompletion()
            activated = true
        }
        await Task { }.value
        #expect(!activated)
        work.finish(7)
        await activation.value
        #expect(activated)
        #expect(await capture.value == nil)
        #expect(work.callCount == 1)
    }
}
