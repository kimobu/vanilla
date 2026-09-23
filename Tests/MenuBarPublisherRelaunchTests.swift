//
//  MenuBarPublisherRelaunchTests.swift
//  Ice
//

import Testing

struct MenuBarPublisherRelaunchTests {
    @Test func survivingHelperDoesNotCountAsRestartedPublisher() {
        let relaunch = MenuBarPublisherRelaunch(originalProcessIDs: [10, 20])
        #expect(relaunch.action(currentProcessIDs: [20]) == .launchNewInstance)
    }

    @Test func missingPublisherRequiresLaunch() {
        let relaunch = MenuBarPublisherRelaunch(originalProcessIDs: [10])
        #expect(relaunch.action(currentProcessIDs: []) == .launch)
    }

    @Test func automaticReplacementIsNotLaunchedTwice() {
        let relaunch = MenuBarPublisherRelaunch(originalProcessIDs: [10, 20])
        #expect(relaunch.action(currentProcessIDs: [20, 30]) == .alreadyRelaunched)
    }
}
