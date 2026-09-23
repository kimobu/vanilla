//
//  MenuBarPublisherProbes.swift
//  Ice
//

import Foundation

/// Spreads optional AX capability checks across existing discovery passes.
struct MenuBarPublisherProbes {
    struct Process: Hashable, Sendable {
        let id: Int32
        let launchDate: Date?
    }

    private struct Attempt {
        let count: Int
        let nextCheck: ContinuousClock.Instant
    }

    private var attempts = [Process: Attempt]()
    private var firstSeen = [Process: ContinuousClock.Instant]()

    mutating func candidates(
        running: [Process],
        knownPublishers: Set<Int32>,
        now: ContinuousClock.Instant
    ) -> [Process] {
        let runningSet = Set(running)
        attempts = attempts.filter { runningSet.contains($0.key) && !knownPublishers.contains($0.key.id) }
        firstSeen = firstSeen.filter { runningSet.contains($0.key) }
        for process in running where firstSeen[process] == nil { firstSeen[process] = now }
        // Prioritize recent launches and their retries over the initial backlog.
        // Within a launch batch, visit untested processes before overdue retries.
        return running.enumerated()
            .filter { !knownPublishers.contains($0.element.id) && (attempts[$0.element].map { $0.nextCheck <= now } ?? true) }
            .sorted { lhs, rhs in
                if let leftSeen = firstSeen[lhs.element], let rightSeen = firstSeen[rhs.element], leftSeen != rightSeen {
                    return leftSeen > rightSeen
                }
                let left = attempts[lhs.element]?.nextCheck
                let right = attempts[rhs.element]?.nextCheck
                if left == right { return lhs.offset < rhs.offset }
                guard let left else { return true }
                guard let right else { return false }
                return left < right
            }
            .map(\.element)
    }

    mutating func recordAttempt(_ process: Process, now: ContinuousClock.Instant) {
        let count = min((attempts[process]?.count ?? 0) + 1, 3)
        // An app can install its first status item after finishing launch, or later
        // in response to a preference. Failed helpers are not retried every scan.
        let delay: Duration = switch count {
        case 1: .seconds(5)
        case 2: .seconds(30)
        default: .seconds(300)
        }
        attempts[process] = Attempt(count: count, nextCheck: now.advanced(by: delay))
    }
}
