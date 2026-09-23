//
//  PermissionsManager.swift
//  Ice
//

import AppKit
import Combine
import Foundation

/// A type that manages the permissions of the app.
@MainActor
final class PermissionsManager: ObservableObject {
    /// The state of the granted permissions for the app.
    enum PermissionsState: Equatable {
        case missingPermissions
        case hasAllPermissions
        case hasRequiredPermissions
    }

    /// The state of the granted permissions for the app.
    @Published private(set) var permissionsState = PermissionsState.missingPermissions

    let accessibilityPermission: AccessibilityPermission

    let screenRecordingPermission: ScreenRecordingPermission

    let allPermissions: [Permission]

    private(set) weak var appState: AppState?

    private var cancellables = Set<AnyCancellable>()

    var requiredPermissions: [Permission] {
        allPermissions.filter { $0.isRequired }
    }

    init(appState: AppState) {
        self.appState = appState
        self.accessibilityPermission = AccessibilityPermission()
        self.screenRecordingPermission = ScreenRecordingPermission()
        self.allPermissions = [
            accessibilityPermission,
            screenRecordingPermission,
        ]
        configureCancellables()
        updatePermissionsState()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        Publishers.Merge(
            accessibilityPermission.$hasPermission.mapToVoid(),
            screenRecordingPermission.$hasPermission.mapToVoid()
        )
        .sink { [weak self] in
            // Published emits before the stored value changes. Read the models afterward.
            Task { @MainActor [weak self] in
                self?.updatePermissionsState(permissionChanged: true)
            }
        }
        .store(in: &c)

        Publishers.Merge3(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
        )
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissions()
            }
        }
        .store(in: &c)

        cancellables = c
    }

    private func updatePermissionsState(permissionChanged: Bool = false) {
        let state: PermissionsState
        if allPermissions.allSatisfy({ $0.hasPermission }) {
            state = .hasAllPermissions
        } else if requiredPermissions.allSatisfy({ $0.hasPermission }) {
            state = .hasRequiredPermissions
        } else {
            state = .missingPermissions
        }
        if permissionsState != state {
            permissionsState = state
        } else if permissionChanged {
            // Settings reads individual permissions through this observable manager.
            objectWillChange.send()
        }
    }

    /// Refreshes both models without restarting their onboarding timers.
    func refreshPermissions() {
        for permission in allPermissions {
            permission.refresh()
        }
        updatePermissionsState()
    }

    /// Stops onboarding polling. Activation and wake still recheck permission state.
    func stopAllChecks() {
        for permission in allPermissions {
            permission.stopCheck()
        }
    }
}
