//
//  Permission.swift
//  Ice
//

import Combine
import Cocoa

// MARK: - Permission

/// An object that encapsulates the behavior of checking for and requesting
/// a specific permission for the app.
@MainActor
class Permission: ObservableObject, Identifiable {
    /// A Boolean value that indicates whether the app has this permission.
    @Published private(set) var hasPermission = false

    /// The title of the permission.
    let title: String
    /// Descriptive details for the permission.
    let details: [String]
    /// A Boolean value that indicates if the app can work without this permission.
    let isRequired: Bool

    /// The URL of the settings pane to open.
    private let settingsURL: URL?
    /// The function that checks permissions.
    private let check: () -> Bool
    /// The function that requests permissions.
    private let request: () -> Void

    /// Observer that runs on a timer to check permissions.
    private var timerCancellable: AnyCancellable?
    /// One pending UI action, replaced if the user requests the permission again.
    private var onGranted: (() -> Void)?

    /// Creates a permission.
    ///
    /// - Parameters:
    ///   - title: The title of the permission.
    ///   - details: Descriptive details for the permission.
    ///   - isRequired: A Boolean value that indicates if the app can work without this permission.
    ///   - settingsURL: The URL of the settings pane to open.
    ///   - check: A function that checks permissions.
    ///   - request: A function that requests permissions.
    init(
        title: String,
        details: [String],
        isRequired: Bool,
        settingsURL: URL?,
        check: @escaping () -> Bool,
        request: @escaping () -> Void
    ) {
        self.title = title
        self.details = details
        self.isRequired = isRequired
        self.settingsURL = settingsURL
        self.check = check
        self.request = request
        self.hasPermission = check()
        configureCancellables()
    }

    /// Sets up the internal observers for the permission.
    private func configureCancellables() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                refresh()
            }
    }

    /// Rechecks permission and delivers a pending action exactly once after a grant.
    func refresh() {
        let granted = check()
        if hasPermission != granted {
            hasPermission = granted
        }
        guard hasPermission, let action = onGranted else { return }
        onGranted = nil
        action()
    }

    /// Requests permission and invokes the action after the system reports a grant.
    /// There is no suspended task to retain when the permissions window closes.
    func performRequest(onGranted: @escaping () -> Void = {}) {
        self.onGranted = onGranted
        configureCancellables()
        guard !hasPermission else { return }
        request()
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Stops checking permissions and discards any pending UI action.
    func stopCheck() {
        timerCancellable?.cancel()
        timerCancellable = nil
        onGranted = nil
    }
}
