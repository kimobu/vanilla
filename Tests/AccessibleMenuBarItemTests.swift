//
//  AccessibleMenuBarItemTests.swift
//  Ice
//

import Foundation
import Testing

struct AccessibleMenuBarItemTests {
    @Test func publisherSelectionIncludesHiddenItemsAndDeduplicatesApps() throws {
        let visible = item(identifier: "visible")
        let hidden = item(identifier: "hidden", x: -4000)
        let overflow = AccessibleMenuBarItem(
            id: UUID(),
            processID: 456,
            bundleIdentifier: "example.overflow",
            applicationName: "Overflow",
            accessibilityIdentifier: nil,
            label: nil,
            frame: nil,
            actions: []
        )
        let snapshot = MenuBarAccessibilitySnapshot(items: [visible, hidden, overflow], isComplete: true, unavailableProcessIDs: [])
        #expect(try snapshot.publisherProcessIDs() == [123, 456])
    }

    @Test func publisherSelectionRejectsPartialReads() {
        for snapshot in [
            MenuBarAccessibilitySnapshot(items: [item(identifier: "known")], isComplete: false, unavailableProcessIDs: []),
            MenuBarAccessibilitySnapshot(items: [item(identifier: "known")], isComplete: true, unavailableProcessIDs: [456]),
        ] {
            #expect(throws: MenuBarAccessibilitySnapshot.IncompleteReadError.self) {
                try snapshot.publisherProcessIDs()
            }
        }
    }

    @Test func offscreenItemAssignedToHiddenIsNotAlsoRetainedInVisible() {
        let hidden = item(identifier: "wifi", x: -3751)
        let bar = CGRect(x: 0, y: 0, width: 1920, height: 30)
        #expect(hidden.isOnMenuBarRow(in: bar))
        #expect(!hidden.isLocated(in: bar))
        let visible = AccessibleMenuBarItem.retainingUnpositionedItems(
            current: [],
            previous: [hidden],
            snapshot: [hidden],
            menuBarBounds: [bar],
            assignedItemIDs: [hidden.id]
        )
        #expect(visible.isEmpty)
        let retainedHidden = AccessibleMenuBarItem.retainingUnpositionedItems(
            current: [hidden],
            previous: [],
            snapshot: [hidden],
            menuBarBounds: [bar],
            assignedItemIDs: [hidden.id]
        )
        #expect(retainedHidden == [hidden])
    }

    @Test func assignedItemsDoNotSuppressOtherUnpositionedItems() {
        let assigned = withoutFrame(item(identifier: "assigned"))
        let overflow = withoutFrame(item(identifier: "overflow"))
        let retained = AccessibleMenuBarItem.retainingUnpositionedItems(
            current: [],
            previous: [assigned, overflow],
            snapshot: [assigned, overflow],
            menuBarBounds: [CGRect(x: 0, y: 0, width: 1920, height: 30)],
            assignedItemIDs: [assigned.id]
        )
        #expect(retained == [overflow])
    }

    @Test func hiddenPublisherCoordinatesRemainOnTheirMenuBarRow() {
        let bar = CGRect(x: 0, y: 0, width: 1920, height: 30)
        let hidden = item(identifier: "hidden", x: -3751)
        #expect(hidden.isOnMenuBarRow(in: bar))
        #expect(!hidden.isLocated(in: bar))
        #expect(!hidden.isOnMenuBarRow(in: CGRect(x: 0, y: -1080, width: 1920, height: 30)))
        #expect(!hidden.removingFrame().isOnMenuBarRow(in: bar))
    }

    @Test func menuBarRowRejectsPlaceholderAndOverflowPanelGeometry() {
        let bar = CGRect(x: 0, y: 0, width: 1920, height: 30)
        for frame in [CGRect.zero, .null, CGRect(x: 0, y: 1080, width: 24, height: 24), CGRect(x: 100, y: 35, width: 24, height: 24)] {
            let placeholder = AccessibleMenuBarItem(
                id: UUID(),
                processID: 1,
                bundleIdentifier: "example.app",
                applicationName: "App",
                accessibilityIdentifier: nil,
                label: nil,
                frame: frame,
                actions: []
            )
            #expect(!placeholder.isOnMenuBarRow(in: bar))
        }
    }

    @Test func dividerExpansionInvalidatesAnOverlappingHostedFrame() {
        let icon = item(identifier: "icon", x: 100)
        let covered = icon.validatingFrame(occludedBy: [CGRect(x: 50, y: 0, width: 658, height: 30)])
        #expect(covered.frame == nil)
        #expect(covered.id == icon.id)
        #expect(icon.validatingFrame(occludedBy: [CGRect(x: 130, y: 0, width: 658, height: 30)]) == icon)
        #expect(icon.validatingFrame(occludedBy: [CGRect(x: 50, y: -377, width: 658, height: 30)]) == icon)
    }

    @Test func invalidatingGeometryPreservesMembershipWithoutLocatingTheItem() {
        let icon = item(identifier: "icon", label: "Current icon", x: 100)
        let invalidated = icon.removingFrame()
        let bar = CGRect(x: 0, y: 0, width: 500, height: 30)
        #expect(icon.isLocated(in: bar))
        #expect(!invalidated.isLocated(in: bar))
        let retained = AccessibleMenuBarItem.retainingUnpositionedItems(
            current: [], previous: [icon], snapshot: [invalidated], menuBarBounds: [bar]
        )
        #expect(retained == [invalidated])
        #expect(retained.first?.id == icon.id)
        #expect(retained.first?.label == icon.label)
        #expect(retained.first?.actions == icon.actions)
    }

    @Test func changingLabelAndPositionDoNotChangePersistentIdentity() throws {
        let before = item(identifier: "clock", label: "9:00", x: 1200)
        let after = item(identifier: "clock", label: "9:01", x: -200)
        let original = try #require(AccessibleMenuBarItem.persistentIdentities(in: [before])[before.id])
        let moved = try #require(AccessibleMenuBarItem.persistentIdentities(in: [after])[after.id])
        #expect(original == moved)
    }

    @Test func missingAndDuplicateIdentifiersAreNotSavedAsDistinctItems() {
        let items = [item(identifier: nil), item(identifier: ""), item(identifier: "same"), item(identifier: "same")]
        #expect(AccessibleMenuBarItem.persistentIdentities(in: items).isEmpty)
        #expect(Set(items.map(\.id)).count == 4)
    }

    @Test func publishingAppsDisambiguateTheSameIdentifier() {
        let first = item(identifier: "icon", bundle: "example.first")
        let second = item(identifier: "icon", bundle: "example.second")
        let identities = AccessibleMenuBarItem.persistentIdentities(in: [first, second])
        #expect(identities.count == 2)
        #expect(identities[first.id] != identities[second.id])
    }

    @Test func duplicateHandlesCollapseOnlyAtTheSamePhysicalControl() {
        let first = item(identifier: "clock", x: 100)
        #expect(first.representsSameControl(as: item(identifier: "clock", label: "Updated", x: 100)))
        #expect(!first.representsSameControl(as: item(identifier: "clock", x: -200)))
        #expect(!first.representsSameControl(as: item(identifier: "wifi", x: 100)))
        #expect(!item(identifier: nil).representsSameControl(as: item(identifier: nil)))
    }

    @Test func placementUsesNeighborsWithGapsRatherThanTouchingEdges() {
        let first = item(identifier: "first", x: 100)
        let second = item(identifier: "second", x: 160)
        let third = item(identifier: "third", x: 220)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
        let items = [third, first, second]
        #expect(AccessibleMenuBarItem.hasPlacement(itemID: first.id, targetID: second.id, placement: .before, items: items, displayBounds: bounds))
        #expect(AccessibleMenuBarItem.hasPlacement(itemID: second.id, targetID: first.id, placement: .after, items: items, displayBounds: bounds))
        #expect(!AccessibleMenuBarItem.hasPlacement(itemID: first.id, targetID: third.id, placement: .before, items: items, displayBounds: bounds))
        #expect(!AccessibleMenuBarItem.hasPlacement(itemID: first.id, targetID: first.id, placement: .before, items: items, displayBounds: bounds))
        #expect(!AccessibleMenuBarItem.hasPlacement(itemID: UUID(), targetID: first.id, placement: .after, items: items, displayBounds: bounds))
    }

    @Test func placementRejectsCoincidentOverflowFrames() {
        let first = item(identifier: "first", x: 1031)
        let second = item(identifier: "second", x: 1031)
        let bounds = CGRect(x: 0, y: 0, width: 1800, height: 39)
        for items in [[first, second], [second, first]] {
            #expect(!AccessibleMenuBarItem.hasPlacement(itemID: first.id, targetID: second.id, placement: .before, items: items, displayBounds: bounds))
            #expect(!AccessibleMenuBarItem.hasPlacement(itemID: first.id, targetID: second.id, placement: .after, items: items, displayBounds: bounds))
        }
    }

    @Test func placementRejectsPartiallyOverlappingFrames() {
        let first = item(identifier: "first", x: 100)
        let second = item(identifier: "second", x: 110)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
        #expect(!AccessibleMenuBarItem.hasPlacement(itemID: first.id, targetID: second.id, placement: .before, items: [first, second], displayBounds: bounds))
        #expect(!AccessibleMenuBarItem.hasPlacement(itemID: second.id, targetID: first.id, placement: .after, items: [first, second], displayBounds: bounds))
    }

    @Test func placementAcceptsTouchingFrames() throws {
        let first = item(identifier: "first", x: 100)
        let second = item(identifier: "second", x: try #require(first.frame).maxX)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
        #expect(AccessibleMenuBarItem.hasPlacement(itemID: first.id, targetID: second.id, placement: .before, items: [second, first], displayBounds: bounds))
        #expect(AccessibleMenuBarItem.hasPlacement(itemID: second.id, targetID: first.id, placement: .after, items: [second, first], displayBounds: bounds))
    }

    @Test func placementDoesNotMixDisplays() {
        let first = item(identifier: "first", x: -200)
        let second = item(identifier: "second", x: -150)
        let elsewhere = item(identifier: "third", x: 100)
        let bounds = CGRect(x: -500, y: 0, width: 500, height: 300)
        let items = [first, second, elsewhere]
        #expect(AccessibleMenuBarItem.hasPlacement(itemID: first.id, targetID: second.id, placement: .before, items: items, displayBounds: bounds))
        #expect(!AccessibleMenuBarItem.hasPlacement(itemID: second.id, targetID: elsewhere.id, placement: .before, items: items, displayBounds: bounds))
    }

    @Test func retainsNegativeDisplayCoordinatesAndRejectsUnusableFrames() {
        #expect(AccessibleMenuBarItem.validFrame(origin: CGPoint(x: -200, y: -377), size: CGSize(width: 24, height: 30)) == CGRect(x: -200, y: -377, width: 24, height: 30))
        #expect(AccessibleMenuBarItem.validFrame(origin: .zero, size: .zero) == nil)
        #expect(AccessibleMenuBarItem.validFrame(origin: CGPoint(x: CGFloat.infinity, y: 0), size: CGSize(width: 24, height: 30)) == nil)
        #expect(AccessibleMenuBarItem.validFrame(origin: .zero, size: CGSize(width: -1, height: 30)) == nil)
    }

    @Test func overflowKeepsItsSectionOrderAndCurrentLabels() {
        let first = item(identifier: "first", x: 100)
        let middle = item(identifier: "middle", x: 140)
        let last = item(identifier: "last", x: 180)
        let hiddenFirst = withoutFrame(first, label: "Updated first")
        let hiddenMiddle = withoutFrame(middle, label: "Updated middle")
        let result = AccessibleMenuBarItem.retainingUnpositionedItems(
            current: [last],
            previous: [first, middle, last],
            snapshot: [hiddenMiddle, last, hiddenFirst],
            menuBarBounds: [CGRect(x: 0, y: 0, width: 500, height: 30)]
        )
        #expect(result.map(\.id) == [first.id, middle.id, last.id])
        #expect(result.first?.label == "Updated first")
        #expect(result.first?.frame == nil)
    }

    @Test func stalePublisherFramesAreNotCaptureGeometry() {
        let icon = item(identifier: "icon", x: 100)
        let visible = icon.validatingFrame(hostedFrames: [CGRect(x: 94, y: 0, width: 38, height: 30)])
        #expect(visible.frame == icon.frame)
        #expect(icon.validatingFrame(hostedFrames: []).frame == nil)
        #expect(icon.validatingFrame(hostedFrames: [CGRect(x: 120, y: 0, width: 24, height: 30)]).frame == nil)
        // A wide spacer containing the old position is not the same hosted control.
        #expect(icon.validatingFrame(hostedFrames: [CGRect(x: 0, y: 0, width: 658, height: 30)]).frame == nil)
        #expect(icon.validatingFrame(hostedFrames: [CGRect(x: 100, y: -377, width: 24, height: 30)]).frame == nil)
        #expect(icon.validatingFrame(hostedFrames: []).id == icon.id)
    }

    @Test func removedAndOtherDisplayItemsAreNotRetainedAsOverflow() {
        let removed = item(identifier: "removed")
        let otherDisplay = item(identifier: "elsewhere", x: -200)
        let unknown = withoutFrame(item(identifier: nil))
        let result = AccessibleMenuBarItem.retainingUnpositionedItems(
            current: [],
            previous: [removed, otherDisplay],
            snapshot: [otherDisplay, unknown],
            menuBarBounds: [CGRect(x: 0, y: 0, width: 500, height: 30), CGRect(x: -500, y: 0, width: 500, height: 30)]
        )
        #expect(result.isEmpty)
    }

    @Test func positionedItemsUseTheirNewOrderWithoutDuplicates() {
        let first = item(identifier: "first", x: 100)
        let second = item(identifier: "second", x: 140)
        let third = item(identifier: "third", x: 180)
        let hidden = withoutFrame(third)
        let result = AccessibleMenuBarItem.retainingUnpositionedItems(
            current: [second, first],
            previous: [first, second, third],
            snapshot: [first, second, hidden],
            menuBarBounds: [CGRect(x: 0, y: 0, width: 500, height: 30)]
        )
        #expect(result.map(\.id) == [second.id, first.id, third.id])
    }

    @Test func overlappingAppInstancesUseTheSameMovementBoundary() {
        let first = item(identifier: "account-a", x: 100, processID: 123)
        let second = item(identifier: "account-b", x: 122, processID: 456)
        let neighbor = item(identifier: "neighbor", bundle: "other.app", x: 152)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 30)
        for member in [first, second] {
            let group = AccessibleMenuBarItem.movementGroup(containing: member.id, items: [neighbor, second, first], menuBarBounds: bounds)
            #expect(group.map(\.id) == [first.id, second.id])
            #expect(AccessibleMenuBarItem.hasPlacement(itemID: second.id, targetID: neighbor.id, placement: .before, items: [first, second, neighbor], displayBounds: bounds))
        }
        #expect(AccessibleMenuBarItem.movementGroup(containing: neighbor.id, items: [first, second, neighbor], menuBarBounds: bounds) == [neighbor])
    }

    @Test func movementGroupsDoNotCombineIndependentOrUnusableFrames() {
        let first = item(identifier: "first", x: 100)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 30)
        let independent = [
            item(identifier: "same-process", x: 122),
            item(identifier: "other-app", bundle: "other.app", x: 122, processID: 456),
            item(identifier: "coincident", x: 100, processID: 456),
            item(identifier: "touching", x: 124, processID: 456),
            item(identifier: "separate", x: 130, processID: 456),
            withoutFrame(item(identifier: "missing", x: 122, processID: 456)),
        ]
        for other in independent {
            #expect(AccessibleMenuBarItem.movementGroup(containing: first.id, items: [first, other], menuBarBounds: bounds) == [first])
        }
        #expect(AccessibleMenuBarItem.movementGroup(containing: first.id, items: [first], menuBarBounds: CGRect(x: -500, y: 0, width: 500, height: 30)).isEmpty)
    }

    @Test func nativeReplacementKeepsIdentityAndDiscardsStaleWrapper() throws {
        let old = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", x: 300)
        let replacement = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", x: 100)
        let neighbor = item(identifier: "divider", x: 140)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 40)
        let resolved = AccessibleMenuBarItem.resolvingNativeControls(
            current: [old, replacement, neighbor], previous: [old], hitItemIDs: [replacement.id], displayBounds: [bounds]
        )
        let wifi = try #require(resolved.first { $0.elementID == replacement.id })
        #expect(wifi.item.id == old.id)
        #expect(wifi.item.frame == replacement.frame)
        #expect(resolved.count == 2)
        #expect(AccessibleMenuBarItem.hasPlacement(itemID: old.id, targetID: neighbor.id, placement: .before, items: resolved.map(\.item), displayBounds: bounds))
    }

    @Test func nativeReplacementDoesNotDuplicateARetainedHiddenIdentity() {
        let original = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", x: 300)
        let replacement = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", x: 100)
        let resolved = AccessibleMenuBarItem.resolvingNativeControls(
            current: [original.removingFrame(), replacement],
            previous: [original],
            hitItemIDs: [replacement.id],
            displayBounds: [CGRect(x: 0, y: 0, width: 500, height: 40)]
        )
        #expect(resolved.count == 1)
        #expect(resolved.first?.item.id == original.id)
        #expect(resolved.first?.elementID == replacement.id)
    }

    @Test func nativeReplacementThroughOverflowAnimationKeepsOneIdentity() throws {
        let original = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", x: 300)
        let shadow = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", x: 100)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 40)
        let hidden = AccessibleMenuBarItem.resolvingNativeControls(
            current: [original, shadow], previous: [original], hitItemIDs: [], displayBounds: [bounds]
        )
        #expect(hidden.count == 1)
        #expect(hidden.first?.item.id == original.id)
        let revealed = AccessibleMenuBarItem.resolvingNativeControls(
            current: [original, shadow], previous: [original], hitItemIDs: [shadow.id], displayBounds: [bounds]
        )
        #expect(revealed.count == 1)
        #expect(revealed.first?.item.id == original.id)
        #expect(revealed.first?.elementID == shadow.id)
    }

    @Test func nativeControlsOnOtherDisplaysAndMultipleLiveControlsStayDistinct() {
        let first = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", x: 100)
        let otherDisplay = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", x: 600)
        let replacement = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", x: 200)
        let displays = [CGRect(x: 0, y: 0, width: 500, height: 40), CGRect(x: 500, y: 0, width: 500, height: 40)]
        let resolved = AccessibleMenuBarItem.resolvingNativeControls(
            current: [first, replacement, otherDisplay], previous: [first, otherDisplay], hitItemIDs: [replacement.id, otherDisplay.id], displayBounds: displays
        )
        #expect(resolved.map { $0.item.id } == [first.id, otherDisplay.id])
        let ambiguous = AccessibleMenuBarItem.resolvingNativeControls(
            current: [first, replacement], previous: [first], hitItemIDs: [first.id, replacement.id], displayBounds: displays
        )
        #expect(ambiguous.map { $0.item.id } == [first.id, replacement.id])
    }

    @Test func nativeResolutionDoesNotMatchAnotherProcessOrAnAppByLabel() {
        let old = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent")
        let relaunched = item(identifier: "wifi", bundle: "com.apple.MenuBarAgent", processID: 456)
        let app = item(identifier: "wifi", label: "Wi-Fi")
        let resolved = AccessibleMenuBarItem.resolvingNativeControls(
            current: [relaunched, app], previous: [old], hitItemIDs: [relaunched.id], displayBounds: [CGRect(x: 0, y: 0, width: 500, height: 40)]
        )
        #expect(resolved.map { $0.item.id } == [relaunched.id, app.id])
        #expect(resolved.last?.item.frame == app.frame)
    }

    private func withoutFrame(_ item: AccessibleMenuBarItem, label: String? = nil) -> AccessibleMenuBarItem {
        AccessibleMenuBarItem(
            id: item.id,
            processID: item.processID,
            bundleIdentifier: item.bundleIdentifier,
            applicationName: item.applicationName,
            accessibilityIdentifier: item.accessibilityIdentifier,
            label: label ?? item.label,
            frame: nil,
            actions: item.actions
        )
    }

    private func item(identifier: String?, bundle: String = "example.app", label: String = "CPU 5%", x: CGFloat = 100, processID: pid_t = 123) -> AccessibleMenuBarItem {
        AccessibleMenuBarItem(
            id: UUID(),
            processID: processID,
            bundleIdentifier: bundle,
            applicationName: "Example",
            accessibilityIdentifier: identifier,
            label: label,
            frame: CGRect(x: x, y: 0, width: 24, height: 30),
            actions: ["AXPress"]
        )
    }
}
