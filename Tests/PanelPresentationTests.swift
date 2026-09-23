//
//  PanelPresentationTests.swift
//  Ice
//

import Testing

@MainActor
struct PanelPresentationTests {
    @MainActor
    private final class Preparation {
        var continuation: CheckedContinuation<Void, Never>?
        var finished = false
        var wasCancelled = false

        func run() async {
            await withCheckedContinuation { continuation = $0 }
            wasCancelled = Task.isCancelled
            finished = true
        }

        func waitUntilStarted() async {
            while continuation == nil { await Task.yield() }
        }

        func finish() async {
            continuation?.resume()
            continuation = nil
            while !finished { await Task.yield() }
        }
    }

    @Test(.timeLimit(.minutes(1))) func immediateDismissalDoesNotStartPreparation() async {
        let presentation = PanelPresentation()
        var prepared = false
        var shown = false
        presentation.show { prepared = true } present: { shown = true }
        #expect(presentation.isRequested)
        presentation.dismiss()
        // Queue this behind the cancelled worker on the main actor.
        await Task { }.value
        #expect(!presentation.isRequested)
        #expect(!prepared)
        #expect(!shown)
    }

    @Test(.timeLimit(.minutes(1))) func dismissalDuringCapturePreventsLatePresentation() async {
        let presentation = PanelPresentation()
        let preparation = Preparation()
        var shown = false
        presentation.show { await preparation.run() } present: { shown = true }
        await preparation.waitUntilStarted()
        #expect(presentation.isRequested)
        presentation.dismiss()
        await preparation.finish()
        #expect(preparation.wasCancelled)
        #expect(!presentation.isRequested)
        #expect(!shown)
    }

    @Test(.timeLimit(.minutes(1))) func replacedCaptureCannotShowOrDismissTheNewPanel() async {
        let presentation = PanelPresentation()
        let old = Preparation()
        let new = Preparation()
        var shown = [Int]()
        presentation.show { await old.run() } present: { shown.append(1) }
        await old.waitUntilStarted()
        presentation.show { await new.run() } present: { shown.append(2) }
        await new.waitUntilStarted()
        await new.finish()
        await old.finish()
        #expect(shown == [2])
        #expect(presentation.isRequested)
        #expect(old.wasCancelled)
        #expect(!new.wasCancelled)
    }

    @Test(.timeLimit(.minutes(1))) func releasingRequestOwnerCancelsPreparation() async {
        var presentation: PanelPresentation? = PanelPresentation()
        weak let weakPresentation = presentation
        let preparation = Preparation()
        var shown = false
        presentation?.show { await preparation.run() } present: { shown = true }
        await preparation.waitUntilStarted()
        presentation = nil
        #expect(weakPresentation == nil)
        await preparation.finish()
        #expect(preparation.wasCancelled)
        #expect(!shown)
    }

    @Test(.timeLimit(.minutes(1))) func presentationCallbackCanDismissAndRequestAnotherPanel() async {
        let presentation = PanelPresentation()
        let first = Preparation()
        let second = Preparation()
        var shown = [Int]()
        presentation.show { await first.run() } present: {
            shown.append(1)
            presentation.dismiss()
            presentation.show { await second.run() } present: { shown.append(2) }
        }
        await first.waitUntilStarted()
        await first.finish()
        await second.waitUntilStarted()
        #expect(presentation.isRequested)
        await second.finish()
        #expect(shown == [1, 2])
    }

    @Test(.timeLimit(.minutes(1))) func panelIsUsableBeforeRefreshCompletesAndDismissalCancelsItsWaiter() async {
        let presentation = PanelPresentation()
        let refresh = Preparation()
        var shown = false
        presentation.show {} present: { shown = true } refresh: { await refresh.run() }
        await refresh.waitUntilStarted()
        #expect(shown)
        #expect(!refresh.finished)
        presentation.dismiss()
        await refresh.finish()
        #expect(refresh.wasCancelled)
        #expect(!presentation.isRequested)
    }

    @Test(.timeLimit(.minutes(1))) func replacedRefreshCannotClearNewRefreshOwnership() async {
        let presentation = PanelPresentation()
        let old = Preparation()
        let new = Preparation()
        presentation.show {} present: {} refresh: { await old.run() }
        await old.waitUntilStarted()
        presentation.show {} present: {} refresh: { await new.run() }
        await new.waitUntilStarted()
        await old.finish()
        presentation.dismiss()
        await new.finish()
        #expect(old.wasCancelled)
        #expect(new.wasCancelled)
    }

    @Test(.timeLimit(.minutes(1))) func releasingOwnerCancelsPostPresentationRefresh() async {
        var presentation: PanelPresentation? = PanelPresentation()
        weak let owner = presentation
        let refresh = Preparation()
        presentation?.show {} present: {} refresh: { await refresh.run() }
        await refresh.waitUntilStarted()
        presentation = nil
        #expect(owner == nil)
        await refresh.finish()
        #expect(refresh.wasCancelled)
    }
}
