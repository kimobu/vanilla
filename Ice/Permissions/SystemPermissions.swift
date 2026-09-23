//
//  SystemPermissions.swift
//  Ice
//

import AXSwift
import Foundation

// MARK: - AccessibilityPermission

final class AccessibilityPermission: Permission {
    init() {
        super.init(
            title: "Accessibility",
            details: [
                "Get real-time information about the menu bar.",
                "Arrange menu bar items.",
            ],
            isRequired: true,
            settingsURL: nil,
            check: {
                checkIsProcessTrusted()
            },
            request: {
                checkIsProcessTrusted(prompt: true)
            }
        )
    }
}

// MARK: - ScreenRecordingPermission

final class ScreenRecordingPermission: Permission {
    init() {
        super.init(
            title: "Screen Recording",
            details: [
                "Edit the menu bar's appearance.",
                "Display images of individual menu bar items.",
            ],
            isRequired: false,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            check: {
                ScreenCapture.cachedCheckPermissions(reset: true)
            },
            request: {
                ScreenCapture.requestPermissions()
            }
        )
    }
}
