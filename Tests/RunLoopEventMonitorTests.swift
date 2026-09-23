//
//  RunLoopEventMonitorTests.swift
//  Ice
//

import Cocoa
import Testing

@MainActor
struct RunLoopEventMonitorTests {
    private func keyEvent(_ type: NSEvent.EventType, key: UInt16, timestamp: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: key
        ))
    }

    private func dequeueKeyEvent() -> NSEvent? {
        NSApp.nextEvent(matching: [.keyDown, .keyUp], until: .distantPast, inMode: .eventTracking, dequeue: true)
    }

    @Test func observationPreservesQueueOrderAndDoesNotRepostEvents() throws {
        _ = NSApplication.shared
        let down = try keyEvent(.keyDown, key: 0, timestamp: 1)
        let up = try keyEvent(.keyUp, key: 0, timestamp: 2)
        let next = try keyEvent(.keyDown, key: 1, timestamp: 3)
        for event in [down, up, next] { NSApp.postEvent(event, atStart: false) }
        defer { while dequeueKeyEvent() != nil { } }
        var observed = [NSEvent]()
        let monitor = RunLoopLocalEventMonitor(mask: .keyDown, mode: .eventTracking) { observed.append($0) }

        for _ in 0..<100 { monitor.processPendingEvent() }
        #expect(observed.count == 1)
        #expect(observed.first?.timestamp == down.timestamp)
        #expect(dequeueKeyEvent()?.timestamp == down.timestamp)
        monitor.processPendingEvent()
        #expect(observed.count == 2)
        #expect(observed.last?.timestamp == next.timestamp)
        #expect(dequeueKeyEvent()?.timestamp == up.timestamp)
        #expect(dequeueKeyEvent()?.timestamp == next.timestamp)
        #expect(dequeueKeyEvent() == nil)
        monitor.processPendingEvent()
        #expect(observed.count == 2)
    }

    @Test func reentrantObservationDoesNotDeliverTheSameEventAgain() throws {
        _ = NSApplication.shared
        let event = try keyEvent(.keyDown, key: 0, timestamp: 4)
        NSApp.postEvent(event, atStart: false)
        defer { while dequeueKeyEvent() != nil { } }
        var deliveries = 0
        var monitor: RunLoopLocalEventMonitor?
        monitor = RunLoopLocalEventMonitor(mask: .keyDown, mode: .eventTracking) { _ in
            deliveries += 1
            monitor?.processPendingEvent()
        }
        monitor?.processPendingEvent()
        #expect(deliveries == 1)
        #expect(dequeueKeyEvent()?.timestamp == event.timestamp)
        monitor = nil
    }
}
