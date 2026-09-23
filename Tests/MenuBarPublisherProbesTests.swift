//
//  MenuBarPublisherProbesTests.swift
//  Ice
//

import Foundation
import Testing

struct MenuBarPublisherProbesTests {
    private func process(_ id: Int32, launched: TimeInterval = 1) -> MenuBarPublisherProbes.Process {
        MenuBarPublisherProbes.Process(id: id, launchDate: Date(timeIntervalSince1970: launched))
    }

    @Test func untestedProcessesAdvanceAheadOfRetriesAcrossBoundedPasses() {
        var probes = MenuBarPublisherProbes()
        let now = ContinuousClock.now
        let running = (1...6).map { process(Int32($0)) }
        let first = probes.candidates(running: running, knownPublishers: [], now: now)
        for candidate in first.prefix(4) { probes.recordAttempt(candidate, now: now) }
        let next = probes.candidates(running: running, knownPublishers: [], now: now.advanced(by: .seconds(5)))
        #expect(next.map(\.id) == [5, 6, 1, 2, 3, 4])
    }

    @Test func delayedStatusItemsGetRetriesWhileUnresponsiveHelpersBackOff() {
        var probes = MenuBarPublisherProbes()
        let app = process(1)
        let now = ContinuousClock.now
        probes.recordAttempt(app, now: now)
        #expect(probes.candidates(running: [app], knownPublishers: [], now: now.advanced(by: .seconds(4))).isEmpty)
        #expect(probes.candidates(running: [app], knownPublishers: [], now: now.advanced(by: .seconds(5))) == [app])
        probes.recordAttempt(app, now: now.advanced(by: .seconds(5)))
        #expect(probes.candidates(running: [app], knownPublishers: [], now: now.advanced(by: .seconds(34))).isEmpty)
        #expect(probes.candidates(running: [app], knownPublishers: [], now: now.advanced(by: .seconds(35))) == [app])
        probes.recordAttempt(app, now: now.advanced(by: .seconds(35)))
        #expect(probes.candidates(running: [app], knownPublishers: [], now: now.advanced(by: .seconds(334))).isEmpty)
        #expect(probes.candidates(running: [app], knownPublishers: [], now: now.advanced(by: .seconds(335))) == [app])
    }

    @Test func recentLaunchAndItsRetryPrecedeTheStartupBacklog() {
        var probes = MenuBarPublisherProbes()
        let now = ContinuousClock.now
        let old = (1...10).map { process(Int32($0)) }
        _ = probes.candidates(running: old, knownPublishers: [], now: now)
        let added = process(11)
        let running = old + [added]
        let later = now.advanced(by: .seconds(1))
        #expect(probes.candidates(running: running, knownPublishers: [], now: later).first == added)
        probes.recordAttempt(added, now: later)
        #expect(probes.candidates(running: running, knownPublishers: [], now: later).first == old.first)
        #expect(probes.candidates(running: running, knownPublishers: [], now: later.advanced(by: .seconds(5))).first == added)
    }

    @Test func newlyLaunchedAndReusedProcessIDsDoNotInheritRetryDelays() {
        var probes = MenuBarPublisherProbes()
        let old = process(1)
        let now = ContinuousClock.now
        probes.recordAttempt(old, now: now)
        let relaunched = process(1, launched: 2)
        let new = process(2)
        #expect(probes.candidates(running: [relaunched, new], knownPublishers: [], now: now) == [relaunched, new])
        probes.recordAttempt(new, now: now)
        _ = probes.candidates(running: [], knownPublishers: [], now: now)
        #expect(probes.candidates(running: [new], knownPublishers: [], now: now) == [new])
    }

    @Test func establishedPublishersSkipOptionalProbesAndBecomeEligibleAfterRemoval() {
        var probes = MenuBarPublisherProbes()
        let app = process(1)
        let now = ContinuousClock.now
        probes.recordAttempt(app, now: now)
        #expect(probes.candidates(running: [app], knownPublishers: [1], now: now).isEmpty)
        #expect(probes.candidates(running: [app], knownPublishers: [], now: now) == [app])
    }
}
