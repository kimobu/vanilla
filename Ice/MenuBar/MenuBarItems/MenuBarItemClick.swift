//
//  MenuBarItemClick.swift
//  Ice
//

import CoreGraphics
import Foundation

/// A click routed by a verified screen position, without private window fields.
@MainActor
enum MenuBarItemClick {
    private static let eventMarker: Int64 = 0x56414E494C4C41

    /// Panel dismissal ignores our overflow clicks, while real outside clicks
    /// still dismiss Search during its asynchronous image refresh.
    static func isGeneratedEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == eventMarker
    }

    enum ClickError: Error {
        case unsupportedButton
        case eventCreationFailed
    }

    /// Pointer motion lets the system reveal an auto-hidden menu bar.
    /// The caller owns restoring the pointer after activation or cancellation.
    /// https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)
    static func movePointer(to point: CGPoint) throws {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        else { throw ClickError.eventCreationFailed }
        event.flags = CGEventSource.flagsState(.combinedSessionState).intersection(.maskAlphaShift)
        event.post(tap: .cghidEventTap)
    }

    static func perform(at point: CGPoint, button: CGMouseButton) async throws {
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
        default:
            throw ClickError.unsupportedButton
        }
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
            let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
        else { throw ClickError.eventCreationFailed }
        source.localEventsSuppressionInterval = 0
        let flags = CGEventSource.flagsState(.combinedSessionState).intersection(.maskAlphaShift)
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        try Task.checkCancellation()
        // Release even if cancellation arrives while the application handles down.
        // https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)
        down.post(tap: .cghidEventTap)
        defer { up.post(tap: .cghidEventTap) }
        try await Task.sleep(for: .milliseconds(50))
    }
}
