//
//  PermissionTests.swift
//  Ice
//

import Combine
import Testing

@MainActor
struct PermissionTests {
    @MainActor
    private final class Access {
        var granted = false
        var requests = 0

        func permission() -> Permission {
            Permission(title: "Test", details: [], isRequired: false, settingsURL: nil) {
                self.granted
            } request: {
                self.requests += 1
            }
        }
    }

    @Test func grantDeliversPendingActionOnlyOnce() {
        let access = Access()
        let permission = access.permission()
        defer { permission.stopCheck() }
        var completions = 0
        permission.performRequest { completions += 1 }
        permission.refresh()
        #expect(access.requests == 1)
        #expect(completions == 0)
        access.granted = true
        permission.refresh()
        permission.refresh()
        #expect(permission.hasPermission)
        #expect(completions == 1)
    }

    @Test func existingGrantDoesNotRequestAgain() {
        let access = Access()
        access.granted = true
        let permission = access.permission()
        defer { permission.stopCheck() }
        var completed = false
        permission.performRequest { completed = true }
        #expect(completed)
        #expect(access.requests == 0)
    }

    @Test func stoppingDiscardsPendingAction() {
        let access = Access()
        let permission = access.permission()
        var completed = false
        permission.performRequest { completed = true }
        permission.stopCheck()
        access.granted = true
        permission.refresh()
        #expect(!completed)
    }

    @Test func refreshAfterOnboardingTracksGrantAndRevocationWithoutDuplicateUpdates() {
        let access = Access()
        let permission = access.permission()
        permission.stopCheck()
        var observed = [Bool]()
        let observation = permission.$hasPermission.sink { observed.append($0) }
        defer { observation.cancel() }

        permission.refresh()
        access.granted = true
        permission.refresh()
        permission.refresh()
        access.granted = false
        permission.refresh()

        #expect(!permission.hasPermission)
        #expect(observed == [false, true, false])
        #expect(access.requests == 0)
    }

    @Test func repeatedRequestReplacesPendingAction() {
        let access = Access()
        let permission = access.permission()
        defer { permission.stopCheck() }
        var firstCompleted = false
        var secondCompleted = false
        permission.performRequest { firstCompleted = true }
        permission.performRequest { secondCompleted = true }
        access.granted = true
        permission.refresh()
        #expect(!firstCompleted)
        #expect(secondCompleted)
    }
}
