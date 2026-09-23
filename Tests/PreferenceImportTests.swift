//
//  PreferenceImportTests.swift
//  Ice
//

import Foundation
import Testing

@MainActor
struct PreferenceImportTests {
    @Test func importsSettingsAndPositionsWithoutChangingIce() throws {
        let domains = Domains()
        defer { domains.cleanUp() }
        let source: [String: Any] = [
            "ShowIceIcon": false,
            "Hotkeys": Data([1, 2, 3]),
            "MenuBarAppearanceConfigurationV2": Data([4, 5]),
            "hasMigrated0_10_1": true,
            "NSStatusItem Preferred Position IceIcon": 123,
            "NSStatusItem Visible IceIcon": false,
            "SUFeedURL": "https://example.com/old-feed.xml",
            "SUEnableAutomaticChecks": true,
            "NSUnrelatedSetting": "old",
        ]
        domains.defaults.setPersistentDomain(source, forName: domains.source)

        domains.runImport()

        let result = try #require(domains.defaults.persistentDomain(forName: domains.destination))
        #expect(result["ShowIceIcon"] as? Bool == false)
        #expect(result["Hotkeys"] as? Data == Data([1, 2, 3]))
        #expect(result["MenuBarAppearanceConfigurationV2"] as? Data == Data([4, 5]))
        #expect(result["hasMigrated0_10_1"] as? Bool == true)
        #expect(result["NSStatusItem Preferred Position IceIcon"] as? Int == 123)
        #expect(result["NSStatusItem Visible IceIcon"] as? Bool == false)
        #expect(result["SUFeedURL"] == nil)
        #expect(result["SUEnableAutomaticChecks"] == nil)
        #expect(result["NSUnrelatedSetting"] == nil)
        let unchangedSource = try #require(domains.defaults.persistentDomain(forName: domains.source))
        #expect(NSDictionary(dictionary: unchangedSource).isEqual(to: source))
    }

    @Test func preservesExistingVanillaSettingsAndDoesNotReimport() throws {
        let domains = Domains()
        defer { domains.cleanUp() }
        domains.defaults.setPersistentDomain(["ShowIceIcon": true, "ItemSpacingOffset": 9], forName: domains.source)
        domains.defaults.setPersistentDomain(["ShowIceIcon": false, "ItemSpacingOffset": 0], forName: domains.destination)

        domains.runImport()
        var result = try #require(domains.defaults.persistentDomain(forName: domains.destination))
        #expect(result["ShowIceIcon"] as? Bool == false)
        #expect(result["ItemSpacingOffset"] as? Int == 0)

        result.removeValue(forKey: "ShowIceIcon")
        domains.defaults.setPersistentDomain(result, forName: domains.destination)
        domains.runImport()
        let repeated = try #require(domains.defaults.persistentDomain(forName: domains.destination))
        #expect(repeated["ShowIceIcon"] == nil)
        #expect(NSDictionary(dictionary: repeated).isEqual(to: result))
    }

    @Test func freshInstallDoesNotImportIceSettingsAddedLater() throws {
        let domains = Domains()
        defer { domains.cleanUp() }
        domains.runImport()
        domains.defaults.setPersistentDomain(["ShowIceIcon": false], forName: domains.source)
        domains.runImport()
        let result = try #require(domains.defaults.persistentDomain(forName: domains.destination))
        #expect(result[PreferenceImport.completionKey] as? Bool == true)
        #expect(result["ShowIceIcon"] == nil)
    }

    @Test func doesNotModifyTheSourceWhenDomainsMatch() throws {
        let domains = Domains()
        defer { domains.cleanUp() }
        let original: [String: Any] = ["ShowIceIcon": false]
        domains.defaults.setPersistentDomain(original, forName: domains.source)
        PreferenceImport.importIceSettings(defaults: domains.defaults, source: domains.source, destination: domains.source)
        let result = try #require(domains.defaults.persistentDomain(forName: domains.source))
        #expect(NSDictionary(dictionary: result).isEqual(to: original))
    }

    @MainActor
    private struct Domains {
        let defaults = UserDefaults.standard
        let source = "VanillaPreferenceImportTests.Source.\(UUID().uuidString)"
        let destination = "VanillaPreferenceImportTests.Destination.\(UUID().uuidString)"

        func runImport() {
            PreferenceImport.importIceSettings(defaults: defaults, source: source, destination: destination)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: destination)
        }
    }
}
