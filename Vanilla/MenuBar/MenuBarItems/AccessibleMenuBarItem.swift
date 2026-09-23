//
//  AccessibleMenuBarItem.swift
//  Ice
//

import Foundation

/// An Accessibility item has its own identity and bounds, not an individual CG window.
struct AccessibleMenuBarItem: Identifiable, Equatable, Sendable {
    /// Stable while this AX element remains alive; never saved as a preference key.
    let id: UUID
    let processID: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let accessibilityIdentifier: String?
    let label: String?
    /// Global Core Graphics points, including negative display origins.
    let frame: CGRect?
    let actions: [String]

    /// CGRect containment accepts a null rectangle. Missing AX geometry must
    /// instead mean that the item cannot be located in this display region.
    func isLocated(in bounds: CGRect) -> Bool {
        guard let frame, !frame.isNull, !frame.isEmpty else { return false }
        return bounds.contains(frame)
    }

    /// macOS 26 publishers retain real negative x positions for hidden items.
    /// Keep those items on their menu-bar row without accepting overflow-panel
    /// rows or the zero-sized placeholders supplied by Control Center.
    func isOnMenuBarRow(in bounds: CGRect) -> Bool {
        guard let frame, !frame.isNull, !frame.isEmpty else { return false }
        return frame.minY >= bounds.minY && frame.maxY <= bounds.maxY
    }

    /// Publisher AX objects can retain their last bounds after entering overflow.
    /// Match a current host control before using those bounds for capture or input.
    func validatingFrame(hostedFrames: [CGRect]) -> Self {
        let visible = frame.map { frame in
            hostedFrames.contains { host in
                abs(host.midX - frame.midX) <= 2 && abs(host.midY - frame.midY) <= 2
            }
        } ?? false
        return visible ? self : removingFrame()
    }

    /// Discards geometry after a layout change while preserving item identity.
    func removingFrame() -> Self {
        Self(
            id: id,
            processID: processID,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            accessibilityIdentifier: accessibilityIdentifier,
            label: label,
            frame: nil,
            actions: actions
        )
    }

    /// Hosted AX wrappers can briefly keep their previous coordinates after a
    /// divider expands. An icon cannot also occupy the divider's screen region.
    func validatingFrame(occludedBy dividers: [CGRect]) -> Self {
        guard let frame else { return self }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return dividers.contains(where: { $0.contains(center) }) ? removingFrame() : self
    }

    /// MenuBarAgent can expose different AX handles for the same physical control.
    /// Equal names alone are insufficient: controls on other displays stay distinct.
    func representsSameControl(as other: Self) -> Bool {
        guard let accessibilityIdentifier, !accessibilityIdentifier.isEmpty, let frame else { return false }
        return processID == other.processID &&
            accessibilityIdentifier == other.accessibilityIdentifier && frame == other.frame
    }

    struct NativeControlResolution {
        let item: AccessibleMenuBarItem
        let elementID: UUID
    }

    /// MenuBarAgent retains old AX wrappers after a Control Center item moves.
    /// Follow the hit-tested replacement within the same display, keeping the
    /// logical ID used by an in-flight move and by the section/image caches.
    static func resolvingNativeControls(
        current: [Self], previous: [Self], hitItemIDs: Set<UUID>, displayBounds: [CGRect]
    ) -> [NativeControlResolution] {
        struct Key: Hashable {
            let processID: pid_t
            let identifier: String
            let display: Int
        }
        func key(for item: Self) -> Key? {
            guard
                item.bundleIdentifier == "com.apple.MenuBarAgent",
                let identifier = item.accessibilityIdentifier, !identifier.isEmpty,
                let display = displayBounds.firstIndex(where: { item.isLocated(in: $0) })
            else { return nil }
            return Key(processID: item.processID, identifier: identifier, display: display)
        }
        var groups = [Key: [Self]]()
        for item in current {
            if let key = key(for: item) { groups[key, default: []].append(item) }
        }
        var replacements = [UUID: UUID]()
        var discarded = Set<UUID>()
        for (groupKey, candidates) in groups {
            let live = candidates.filter { hitItemIDs.contains($0.id) }
            let former = previous.filter { key(for: $0) == groupKey }
            if live.isEmpty {
                // During overflow animation neither wrapper may be hit-testable.
                // Retain the established handle without introducing its shadow
                // as a second logical item before the replacement becomes live.
                if former.count == 1, let original = former.first, candidates.contains(where: { $0.id == original.id }) {
                    discarded.formUnion(candidates.filter { $0.id != original.id }.map(\.id))
                }
                continue
            }
            discarded.formUnion(candidates.filter { !hitItemIDs.contains($0.id) }.map(\.id))
            // Multiple live controls with the same identifier are genuinely
            // distinct. Never guess their identities from their left/right order.
            if live.count == 1, former.count == 1, let replacement = live.first, let original = former.first {
                guard replacement.id == original.id || !hitItemIDs.contains(original.id) else { continue }
                replacements[replacement.id] = original.id
                if replacement.id != original.id { discarded.insert(original.id) }
            }
        }
        return current.filter { !discarded.contains($0.id) }.map { item in
            let resolved = Self(
                id: replacements[item.id] ?? item.id,
                processID: item.processID,
                bundleIdentifier: item.bundleIdentifier,
                applicationName: item.applicationName,
                accessibilityIdentifier: item.accessibilityIdentifier,
                label: item.label,
                frame: item.frame,
                actions: item.actions
            )
            return NativeControlResolution(item: resolved, elementID: item.id)
        }
    }

    enum Placement {
        case before, after
    }

    /// Keeps known items in their section while AX temporarily cannot locate them
    /// in a menu bar. A complete snapshot still removes items that no longer exist.
    static func retainingUnpositionedItems(
        current: [Self], previous: [Self], snapshot: [Self], menuBarBounds: [CGRect], assignedItemIDs: Set<UUID> = []
    ) -> [Self] {
        var result = current
        let observed = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(current.map(\.id)).union(assignedItemIDs)
        for (index, old) in previous.enumerated() {
            guard
                !currentIDs.contains(old.id),
                let item = observed[old.id],
                !menuBarBounds.contains(where: { item.isLocated(in: $0) })
            else { continue }
            // Anchor to the nearest surviving predecessor, retaining the former
            // order without sorting unavailable frames as if they were at x=0.
            let predecessors = Set(previous.prefix(index).map(\.id))
            if let anchor = result.lastIndex(where: { predecessors.contains($0.id) }) {
                result.insert(item, at: anchor + 1)
            } else {
                result.insert(item, at: 0)
            }
        }
        return result
    }

    /// Separate instances of an app can move together on macOS 27. The
    /// OneDrive pair exposes partially overlapping AX frames even after reveal.
    /// Keep only that observed combination together; matching app names or
    /// bundle IDs alone do not establish a group. Coincident overflow proxies
    /// do not establish usable geometry either.
    /// Verified on 27.0 (26A428); see the September 22 reorder audit.
    static func movementGroup(containing id: UUID, items: [Self], menuBarBounds: CGRect) -> [Self] {
        let ordered = items.filter { $0.isLocated(in: menuBarBounds) }
            .sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return [] }
        func movesTogether(_ left: Self, _ right: Self) -> Bool {
            guard
                let bundle = left.bundleIdentifier, !bundle.isEmpty,
                right.bundleIdentifier == bundle, left.processID != right.processID,
                let lhs = left.frame, let rhs = right.frame,
                lhs.minY == rhs.minY, lhs.height == rhs.height
            else { return false }
            return lhs.minX < rhs.minX && lhs.maxX > rhs.minX && lhs.maxX < rhs.maxX
        }
        var first = index
        var last = index
        while first > 0, movesTogether(ordered[first - 1], ordered[first]) { first -= 1 }
        while last + 1 < ordered.count, movesTogether(ordered[last], ordered[last + 1]) { last += 1 }
        return Array(ordered[first...last])
    }

    /// Checks neighbors, not touching edges: macOS can leave space between icons.
    static func hasPlacement(itemID: UUID, targetID: UUID, placement: Placement, items: [Self], displayBounds: CGRect) -> Bool {
        guard itemID != targetID else { return false }
        let ordered = items.filter { $0.isLocated(in: displayBounds) }
            .sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
        guard let index = ordered.firstIndex(where: { $0.id == itemID }), let target = ordered.firstIndex(where: { $0.id == targetID }) else { return false }
        guard let frame = ordered[index].frame, let targetFrame = ordered[target].frame else { return false }
        // Closed native overflow on macOS 27 can report the same position for
        // several controls. Array order does not establish their physical order.
        // See docs/audits/2026-09-21-notched-overflow.txt.
        return switch placement {
        case .before: index + 1 == target && frame.maxX <= targetFrame.minX
        case .after: index == target + 1 && frame.minX >= targetFrame.maxX
        }
    }

    struct PersistentIdentity: Hashable, Sendable {
        let bundleIdentifier: String
        let accessibilityIdentifier: String
    }

    /// Only an explicit, unambiguous identifier is eligible for saved item settings.
    /// Dynamic labels, positions, PIDs, and enumeration order are not persistent IDs.
    static func persistentIdentities(in items: [Self]) -> [UUID: PersistentIdentity] {
        var candidates = [PersistentIdentity: [UUID]]()
        for item in items {
            guard
                let bundleIdentifier = item.bundleIdentifier, !bundleIdentifier.isEmpty,
                let identifier = item.accessibilityIdentifier, !identifier.isEmpty
            else { continue }
            let identity = PersistentIdentity(bundleIdentifier: bundleIdentifier, accessibilityIdentifier: identifier)
            candidates[identity, default: []].append(item.id)
        }
        var result = [UUID: PersistentIdentity]()
        for (identity, ids) in candidates where ids.count == 1 {
            if let id = ids.first {
                result[id] = identity
            }
        }
        return result
    }

    /// Invalid or zero-sized AX frames mean that capture geometry is unavailable.
    static func validFrame(origin: CGPoint, size: CGSize) -> CGRect? {
        guard
            origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

struct MenuBarAccessibilitySnapshot: Equatable, Sendable {
    let items: [AccessibleMenuBarItem]
    /// A partial read must not be interpreted as items being removed.
    let isComplete: Bool
    let unavailableProcessIDs: Set<pid_t>

    struct IncompleteReadError: LocalizedError {
        var errorDescription: String? { "Could not read the menu bar apps. Try again." }
    }

    /// Publisher identity does not depend on visibility, capture geometry, or
    /// which process hosts the native status-item windows.
    func publisherProcessIDs() throws -> Set<pid_t> {
        guard isComplete, unavailableProcessIDs.isEmpty else { throw IncompleteReadError() }
        return Set(items.map(\.processID))
    }
}
