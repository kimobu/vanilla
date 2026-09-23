//
//  UpdatesManager.swift
//  Ice
//

import Sparkle
import SwiftUI

/// Manager for app updates.
@MainActor
final class UpdatesManager: NSObject, ObservableObject {
    /// Vanilla's updater stays off until the fork supplies its own feed and signing key.
    let isConfigured: Bool = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard
            let feed = info["SUFeedURL"] as? String,
            let key = info["SUPublicEDKey"] as? String
        else {
            return false
        }
        return !feed.isEmpty && !key.isEmpty
    }()

    /// A Boolean value that indicates whether the user can check for updates.
    @Published var canCheckForUpdates = false

    /// The date of the last update check.
    @Published var lastUpdateCheckDate: Date?

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The underlying updater controller.
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: isConfigured,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    /// The underlying updater.
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// A Boolean value that indicates whether to automatically check for updates.
    var automaticallyChecksForUpdates: Bool {
        get {
            updater.automaticallyChecksForUpdates
        }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// A Boolean value that indicates whether to automatically download updates.
    var automaticallyDownloadsUpdates: Bool {
        get {
            updater.automaticallyDownloadsUpdates
        }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Creates an updates manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Sets up the manager.
    func performSetup() {
        guard isConfigured else {
            return
        }
        _ = updaterController
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)
    }

    /// Checks for app updates.
    @objc func checkForUpdates() {
        guard isConfigured else {
            return
        }
        #if DEBUG
        // Checking for updates hangs in debug mode.
        let alert = NSAlert()
        alert.messageText = "Checking for updates is not supported in debug mode."
        alert.runModal()
        #else
        guard let appState else {
            return
        }
        // Activate the app in case an alert needs to be displayed.
        appState.activate(withPolicy: .regular)
        appState.openSettingsWindow()
        updater.checkForUpdates()
        #endif
    }
}

// MARK: UpdatesManager: SPUUpdaterDelegate
extension UpdatesManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        guard let appState else {
            return
        }
        appState.userNotificationManager.requestAuthorization()
    }
}

// MARK: UpdatesManager: SPUStandardUserDriverDelegate
// Sparkle 2.10's standard driver invokes these UI callbacks on the main thread.
// Its Objective-C protocol is not actor-annotated, so keep the bridge synchronous.
// https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUStandardUserDriver.m
extension UpdatesManager: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            NSApp.isActive && immediateFocus
        }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            appState?.userNotificationManager.addRequest(
                with: .updateCheck,
                title: "A new update is available",
                body: "Version \(version) is now available"
            )
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            appState?.userNotificationManager.removeDeliveredNotifications(with: [.updateCheck])
        }
    }
}

// MARK: UpdatesManager: BindingExposable
extension UpdatesManager: BindingExposable { }
