//
//  SearchCompatibilityTests.swift
//  Ice
//

import Ifrit
import Testing

struct SearchCompatibilityTests {
    struct Example: Sendable {
        let query: String
        let titles: [String]
    }

    @Test(arguments: [
        Example(query: "wifi", titles: ["Wi-Fi"]),
        Example(query: "batery", titles: ["Battery"]),
        Example(query: "van", titles: ["Vanilla", "VPN"]),
        Example(query: "zzzz", titles: []),
    ])
    func preservesMenuItemSearchOrder(example: Example) {
        let titles = [
            "Wi-Fi", "Bluetooth", "Battery", "Control Center", "Spotlight", "Time Machine",
            "Dropbox", "OneDrive", "1Password", "Vanilla", "Sound", "Displays", "Focus",
            "Screen Mirroring", "Keyboard", "VPN",
        ]
        let fuse = Fuse(threshold: 0.5)
        let matches = fuse.searchSync(example.query, in: titles).map { titles[$0.index] }
        #expect(matches == example.titles)
    }
}
