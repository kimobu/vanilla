//
//  PreferenceImport.swift
//  Ice
//

import Foundation

/// Copies Ice's saved settings into Vanilla's separate defaults domain once.
@MainActor
enum PreferenceImport {
    static let completionKey = "HasImportedIcePreferences"

    static func importIceSettings(
        defaults: UserDefaults = .standard,
        source: String = "com.jordanbaird.Ice",
        destination: String
    ) {
        guard source != destination else {
            return
        }
        var destinationValues = defaults.persistentDomain(forName: destination) ?? [:]
        guard destinationValues[completionKey] as? Bool != true else {
            return
        }

        let sourceValues = defaults.persistentDomain(forName: source) ?? [:]
        let settingKeys = Set(Defaults.Key.allCases.map(\.rawValue))
        for (key, value) in sourceValues {
            let isStatusItemSetting = key.hasPrefix("NSStatusItem Preferred Position ") ||
                key.hasPrefix("NSStatusItem Visible ")
            guard settingKeys.contains(key) || isStatusItemSetting else {
                continue
            }
            // Existing Vanilla values win, including explicit false and zero values.
            if destinationValues[key] == nil {
                destinationValues[key] = value
            }
        }

        // Keep the source untouched. Do not import Sparkle or system-owned settings.
        destinationValues[completionKey] = true
        defaults.setPersistentDomain(destinationValues, forName: destination)
    }
}
