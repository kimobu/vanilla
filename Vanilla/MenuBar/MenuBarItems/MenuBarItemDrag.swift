//
//  MenuBarItemDrag.swift
//  Ice
//

import CoreGraphics
import Foundation

/// A Command-drag routed by screen position, without private window fields.
@MainActor
enum MenuBarItemDrag {
    enum DragError: Error {
        case eventCreationFailed
    }

    static func perform(from start: CGPoint, to end: CGPoint) async throws {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: start, mouseButton: .left)
        else { throw DragError.eventCreationFailed }
        source.localEventsSuppressionInterval = 0
        let retainedFlags = CGEventSource.flagsState(.combinedSessionState).intersection(.maskAlphaShift)
        down.flags = retainedFlags.union(.maskCommand)
        // Clear the synthetic modifier at release. Leaving Command on mouse-up
        // leaves it in the combined event state and blocks subsequent moves.
        up.flags = retainedFlags
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        try Task.checkCancellation()
        // Once down is posted, every exit releases at the most recent drag point.
        // https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)
        down.post(tap: .cghidEventTap)
        defer { up.post(tap: .cghidEventTap) }
        try await Task.sleep(for: .milliseconds(50))
        for step in 1...12 {
            try Task.checkCancellation()
            let fraction = CGFloat(step) / 12
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            guard let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else {
                throw DragError.eventCreationFailed
            }
            drag.flags = retainedFlags.union(.maskCommand)
            drag.post(tap: .cghidEventTap)
            up.location = point
            try await Task.sleep(for: .milliseconds(16))
        }
    }
}
