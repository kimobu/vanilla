//
//  MenuBarPublisherRelaunch.swift
//  Ice
//

import Foundation

/// Distinguishes a replacement process from helpers that were already running.
struct MenuBarPublisherRelaunch {
    enum Action {
        case alreadyRelaunched
        case launch
        case launchNewInstance
    }

    let originalProcessIDs: Set<pid_t>

    func action(currentProcessIDs: Set<pid_t>) -> Action {
        if !currentProcessIDs.subtracting(originalProcessIDs).isEmpty {
            return .alreadyRelaunched
        }
        return currentProcessIDs.isEmpty ? .launch : .launchNewInstance
    }
}
