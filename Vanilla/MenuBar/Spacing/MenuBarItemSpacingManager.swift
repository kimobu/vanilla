//
//  MenuBarItemSpacingManager.swift
//  Ice
//

import Cocoa

/// Manager for menu bar item spacing.
@MainActor
final class MenuBarItemSpacingManager {
    /// UserDefaults keys.
    private enum Key: String {
        case spacing = "NSStatusItemSpacing"
        case padding = "NSStatusItemSelectionPadding"

        /// The default value for the key.
        var defaultValue: Int {
            switch self {
            case .spacing: 16
            case .padding: 16
            }
        }
    }

    /// An error that groups multiple failed app relaunches.
    private struct GroupedRelaunchError: LocalizedError {
        let failedApps: [String]

        var errorDescription: String? {
            "The following applications could not be restarted:\n" + failedApps.joined(separator: "\n")
        }

        var recoverySuggestion: String? {
            "You may need to log out for the changes to take effect."
        }
    }

    /// Delay before force terminating an app.
    private let forceTerminateDelay = 1

    /// Writes the same current-user, current-host global domain as `defaults -currentHost`.
    /// https://developer.apple.com/documentation/corefoundation/cfpreferencessetvalue(_:_:_:_:_:)
    private func writePreferences(offset: Int) throws {
        struct PreferencesError: LocalizedError {
            var errorDescription: String? { "Could not save menu bar spacing." }
        }
        for key in [Key.spacing, .padding] {
            let value: NSNumber? = offset == 0 ? nil : NSNumber(value: key.defaultValue + offset)
            CFPreferencesSetValue(
                key.rawValue as CFString,
                value,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        }
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else {
            throw PreferencesError()
        }
    }

    /// Returns a log string for the given app.
    private nonisolated func logString(for app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "<NIL>"
    }

    /// Asynchronously signals the given app to quit.
    private func signalAppToQuit(_ app: NSRunningApplication, forceImmediately: Bool = false) async throws {
        if app.isTerminated {
            Logger.spacing.debug("Application \"\(logString(for: app))\" is already terminated")
            return
        } else {
            Logger.spacing.debug("Signaling application \"\(logString(for: app))\" to quit")
        }

        let waiter = TerminationWaiter(app: app, forceTerminateDelay: forceTerminateDelay)
        try await waiter.wait(forceImmediately: forceImmediately)
        Logger.spacing.debug("Application \"\(logString(for: app))\" terminated successfully")
    }

    /// Owns the observation, deadline, and continuation for one app termination.
    @MainActor
    private final class TerminationWaiter {
        private let app: NSRunningApplication
        private let forceTerminateDelay: Int
        private var observation: NSKeyValueObservation?
        private var timeout: Task<Void, Never>?
        private var continuation: CheckedContinuation<Void, any Error>?

        init(app: NSRunningApplication, forceTerminateDelay: Int) {
            self.app = app
            self.forceTerminateDelay = forceTerminateDelay
        }

        func wait(forceImmediately: Bool) async throws {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    observation = app.observe(\.isTerminated, options: [.initial, .new]) { [weak self] _, change in
                        guard change.newValue == true else { return }
                        Task { @MainActor [weak self] in self?.finish(.success(())) }
                    }
                    timeout = Task { [weak self, forceTerminateDelay] in
                        do {
                            try await Task.sleep(for: .seconds(forceTerminateDelay))
                            guard let self else { return }
                            if !app.isTerminated { app.forceTerminate() }
                            try await Task.sleep(for: .seconds(3))
                            finish(app.isTerminated ? .success(()) : .failure(TaskTimeoutError()))
                        } catch is CancellationError {
                            return
                        } catch {
                            self?.finish(.failure(error))
                        }
                    }
                    if forceImmediately {
                        app.forceTerminate()
                    } else {
                        app.terminate()
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
            }
        }

        private func finish(_ result: Result<Void, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            observation = nil
            timeout?.cancel()
            timeout = nil
            continuation.resume(with: result)
        }
    }

    private func runningProcessIDs(bundleIdentifier: String) -> Set<pid_t> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier))
    }

    /// Asynchronously launches the app at the given URL.
    private func launchApp(at applicationURL: URL, bundleIdentifier: String, relaunch: MenuBarPublisherRelaunch) async throws {
        struct RelaunchError: Error { }
        let action = relaunch.action(currentProcessIDs: runningProcessIDs(bundleIdentifier: bundleIdentifier))
        if action == .alreadyRelaunched {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        // A surviving helper can share the publisher's bundle identifier.
        // Reopening that helper does not restore the terminated menu-bar process.
        // Verified with Jump Desktop Connect on macOS 26.5; see the spacing audit.
        configuration.createsNewApplicationInstance = action == .launchNewInstance
        configuration.promptsUserIfNeeded = false
        let app = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        guard !app.isTerminated, !relaunch.originalProcessIDs.contains(app.processIdentifier) else {
            throw RelaunchError()
        }
    }

    /// Asynchronously relaunches the given app.
    private func relaunchApp(_ app: NSRunningApplication) async throws {
        struct RelaunchError: Error { }
        guard
            let url = app.bundleURL,
            let bundleIdentifier = app.bundleIdentifier
        else {
            throw RelaunchError()
        }
        let relaunch = MenuBarPublisherRelaunch(originalProcessIDs: runningProcessIDs(bundleIdentifier: bundleIdentifier))
        if bundleIdentifier == "com.apple.Spotlight" {
            // Spotlight's launch agent restarts after an unsuccessful exit. A
            // normal quit stays stopped, and Launch Services cannot reopen it.
            // Observed on macOS 26.5; see docs/audits/2026-09-21-spacing-runtime.txt.
            try await signalAppToQuit(app, forceImmediately: true)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            repeat {
                try Task.checkCancellation()
                if relaunch.action(currentProcessIDs: runningProcessIDs(bundleIdentifier: bundleIdentifier)) == .alreadyRelaunched {
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            throw RelaunchError()
        }
        try await signalAppToQuit(app)
        if app.isTerminated {
            try await launchApp(at: url, bundleIdentifier: bundleIdentifier, relaunch: relaunch)
        } else {
            throw RelaunchError()
        }
    }

    private func relaunchForSpacing(pid: pid_t) async -> String? {
        guard
            !Task.isCancelled,
            let app = NSRunningApplication(processIdentifier: pid),
            app.bundleIdentifier != "com.apple.controlcenter",
            app.bundleIdentifier != "com.apple.MenuBarAgent",
            app != .current
        else { return nil }
        do {
            try await relaunchApp(app)
            return nil
        } catch {
            guard let name = app.localizedName else { return nil }
            return name
        }
    }

    /// Writes the requested offset before recording it as applied in settings.
    ///
    /// - Note: Calling this restarts all apps with a menu bar item.
    func applyOffset(_ offset: Int, using appState: AppState) async throws {
        try Task.checkCancellation()
        let pids = try await appState.itemManager.menuBarPublisherProcessIDs()
        try Task.checkCancellation()
        try writePreferences(offset: offset)
        // Discovery or a failed write must leave the previous applied value
        // intact. Once written, keep it even if an app cannot be restarted.
        appState.settingsManager.generalSettingsManager.itemSpacingOffset = CGFloat(offset)
        try await Task.sleep(for: .milliseconds(100))

        var failedApps = [String]()

        await withTaskGroup(of: String?.self) { group in
            for pid in pids {
                group.addTask { [self] in
                    await relaunchForSpacing(pid: pid)
                }
            }
            for await failedApp in group {
                if let failedApp {
                    failedApps.append(failedApp)
                }
            }
        }

        try await Task.sleep(for: .milliseconds(100))

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
            do {
                try await signalAppToQuit(app)
            } catch {
                if let name = app.localizedName {
                    failedApps.append(name)
                }
            }
        }

        if !failedApps.isEmpty {
            throw GroupedRelaunchError(failedApps: failedApps)
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let spacing = Logger(category: "Spacing")
}
