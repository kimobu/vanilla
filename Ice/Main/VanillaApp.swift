//
//  VanillaApp.swift
//  Ice
//

import SwiftUI

@main
struct VanillaApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate
    @StateObject private var appState: AppState

    init() {
        // Import before constructing managers or running the older format migrations.
        PreferenceImport.importIceSettings(destination: Constants.bundleIdentifier)
        let appState = AppState()
        _appState = StateObject(wrappedValue: appState)
        MigrationManager.migrateAll(appState: appState)
        appDelegate.assignAppState(appState)
    }

    var body: some Scene {
        SettingsWindow(appState: appState)
        PermissionsWindow(appState: appState)
    }
}
