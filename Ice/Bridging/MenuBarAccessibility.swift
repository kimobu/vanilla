//
//  MenuBarAccessibility.swift
//  Ice
//

import ApplicationServices
import Foundation

/// Owns remote AX handles and synchronous IPC away from the main actor.
///
/// On macOS 27.0 (26A428), each publishing application's AXExtrasMenuBar exposes
/// its items, while native items also occur beneath MenuBarAgent's windows.
/// Walk only those subtrees; a remote AXApplication can expose the app's entire UI.
/// https://developer.apple.com/documentation/applicationservices/axuielement
actor MenuBarAccessibility {
    struct Application: Sendable {
        let processID: pid_t
        let bundleIdentifier: String?
        let name: String
        let launchDate: Date?
    }

    private let reader = MenuBarAccessibilityReader(excludedProcessID: ProcessInfo.processInfo.processIdentifier)

    func snapshot(applications: [Application], local: MenuBarAccessibilitySnapshot, discoverAllCandidates: Bool = false) -> MenuBarAccessibilitySnapshot {
        reader.snapshot(applications: applications, local: local, discoverAllCandidates: discoverAllCandidates)
    }

    func performAction(itemID: UUID, showMenu: Bool) -> Bool {
        reader.performAction(itemID: itemID, showMenu: showMenu)
    }

    struct NativeOverflowPresentation: Sendable {
        let token: UUID
        let point: CGPoint
    }

    @available(macOS 27, *)
    func prepareNativeOverflowPresentation(processID: pid_t, menuBarBounds: CGRect) -> NativeOverflowPresentation? {
        reader.prepareNativeOverflowPresentation(processID: processID, menuBarBounds: menuBarBounds)
    }

    @available(macOS 27, *)
    func nativeOverflowRestorationPoint(_ token: UUID) -> CGPoint? {
        reader.nativeOverflowRestorationPoint(token)
    }

    @available(macOS 27, *)
    func endNativeOverflowPresentation(_ token: UUID) {
        reader.endNativeOverflowPresentation(token)
    }

    /// AX calls for our own process can enter AppKit directly instead of using
    /// remote IPC. Keep those calls and their handles on the main actor.
    /// Crash evidence: docs/audits/2026-09-20-panel-presentation.txt.
    @MainActor
    final class Local {
        private let reader = MenuBarAccessibilityReader(excludedProcessID: nil)

        func snapshot(application: Application) -> MenuBarAccessibilitySnapshot {
            reader.localSnapshot(application: application)
        }

        func performAction(itemID: UUID, showMenu: Bool) -> Bool {
            reader.performAction(itemID: itemID, showMenu: showMenu)
        }
    }
}

/// Each owner has a separate reader. Neither readers nor AX handles cross actors.
private final class MenuBarAccessibilityReader {
    typealias Application = MenuBarAccessibility.Application
    private let excludedProcessID: pid_t?

    init(excludedProcessID: pid_t?) {
        self.excludedProcessID = excludedProcessID
    }

    private struct Entry {
        let id: UUID
        let processID: pid_t
        let element: AXUIElement
    }

    private var entries = [Entry]()
    private var nativeItems = [AccessibleMenuBarItem]()
    private var nativeOverflowPresentation: (token: UUID, processID: pid_t, bounds: CGRect, description: String)?
    private var publisherProbes = MenuBarPublisherProbes()
    private let logger = Logger(category: "MenuBarAccessibility")

    /// macOS 27 exposes the overflow toggle as a direct, agent-owned button.
    /// Hit-testing distinguishes the live button from the stale second window.
    /// Call only after small dividers have settled with overlapping geometry.
    /// Verified on 27.0 (26A428); see the notched-overflow audit.
    @available(macOS 27, *)
    func prepareNativeOverflowPresentation(processID: pid_t, menuBarBounds: CGRect) -> MenuBarAccessibility.NativeOverflowPresentation? {
        guard nativeOverflowPresentation == nil, !Task.isCancelled else { return nil }
        let read = ReadBudget()
        guard
            let button = nativeOverflowButton(processID: processID, menuBarBounds: menuBarBounds, read: read),
            let frame = read.frame(button),
            let description = read.string(button, attribute: kAXDescriptionAttribute), !description.isEmpty
        else { return nil }
        let token = UUID()
        nativeOverflowPresentation = (token, processID, menuBarBounds, description)
        // The native toggle advertises no AX actions on 27.0. Return a
        // verified point; the manager owns input and cursor restoration.
        return MenuBarAccessibility.NativeOverflowPresentation(token: token, point: CGPoint(x: frame.midX, y: frame.midY))
    }

    private func nativeOverflowButton(processID: pid_t, menuBarBounds: CGRect, read: ReadBudget) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        for window in read.children(application, attribute: kAXWindowsAttribute) {
            for button in read.children(window) {
                guard
                    read.processID(for: button) == processID,
                    read.string(button, attribute: kAXRoleAttribute) == kAXButtonRole,
                    let frame = read.frame(button), menuBarBounds.contains(frame),
                    isHitElement(button, frame: frame), read.canContinue
                else { continue }
                return button
            }
        }
        return nil
    }

    @available(macOS 27, *)
    func nativeOverflowRestorationPoint(_ token: UUID) -> CGPoint? {
        guard let presentation = nativeOverflowPresentation, presentation.token == token else { return nil }
        // Cleanup must run even when the arranging task was cancelled. Compare
        // the opaque descriptions, without depending on the system's language.
        // If the user already closed overflow, leave that restored state alone.
        let read = ReadBudget(checksCancellation: false)
        // Resolve the live control again after placement instead of retaining a
        // possibly replaced AX handle from the preceding menu-bar layout.
        guard
            let button = nativeOverflowButton(processID: presentation.processID, menuBarBounds: presentation.bounds, read: read),
            let frame = read.frame(button),
            let description = read.string(button, attribute: kAXDescriptionAttribute),
            description != presentation.description
        else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    @available(macOS 27, *)
    func endNativeOverflowPresentation(_ token: UUID) {
        if nativeOverflowPresentation?.token == token { nativeOverflowPresentation = nil }
    }

    private func isHitElement(_ element: AXUIElement, frame: CGRect) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(system, Float(frame.midX), Float(frame.midY), &hit) == .success,
            let hit
        else { return false }
        return CFEqual(hit, element)
    }

    /// The returned values contain no AX handles and can safely reach UI state.
    func snapshot(applications: [Application], local: MenuBarAccessibilitySnapshot, discoverAllCandidates: Bool = false) -> MenuBarAccessibilitySnapshot {
        if #unavailable(macOS 27) {
            return publisherSnapshot(applications: applications, local: local, discoverAllCandidates: discoverAllCandidates)
        }
        guard let agent = applications.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" }) else {
            return MenuBarAccessibilitySnapshot(items: [], isComplete: false, unavailableProcessIDs: [])
        }

        // Probe before starting the item-read deadline, as on macOS 26. A full
        // discovery pass can use two seconds; it must not consume the budget
        // for reading known items or leave hosted geometry aging during probing.
        let runningProcesses = Set(applications.map(\.processID))
        var publishingProcessIDs = Set(entries.lazy.map(\.processID).filter { $0 != agent.processID && runningProcesses.contains($0) })
        discoverPublishers(applications: applications, known: &publishingProcessIDs, agentID: agent.processID, discoverAllCandidates: discoverAllCandidates)

        let read = ReadBudget()
        var items = [AccessibleMenuBarItem]()
        var nextEntries = [Entry]()

        let agentElement = AXUIElementCreateApplication(agent.processID)
        let windows = read.children(agentElement, attribute: kAXWindowsAttribute)
        for window in windows {
            collect(window, application: agent, depth: 0, read: read, items: &items, entries: &nextEntries, publishers: &publishingProcessIDs)
        }

        for application in applications where publishingProcessIDs.contains(application.processID) && application.processID != excludedProcessID {
            guard read.canContinue else { break }
            let app = AXUIElementCreateApplication(application.processID)
            if let extras = read.element(app, attribute: kAXExtrasMenuBarAttribute) {
                collect(extras, application: application, depth: 0, read: read, items: &items, entries: &nextEntries, publishers: &publishingProcessIDs)
            }
        }

        // Native controls leave the hosted window tree while hidden. Keep a
        // known, still-valid AX element, without treating its old bounds as live.
        // Invalid elements are removed normally (including a removed menu extra).
        let discovered = Set(nextEntries.map(\.id))
        for entry in entries where entry.processID == agent.processID && !discovered.contains(entry.id) {
            guard read.canContinue else { break }
            guard read.isRetainedMenuBarItem(entry.element) else { continue }
            let start = items.count
            collect(entry.element, application: agent, depth: 0, read: read, items: &items, entries: &nextEntries, publishers: &publishingProcessIDs)
            for index in start..<items.count { items[index] = items[index].removingFrame() }
        }

        reconcileNativeControls(items: &items, entries: &nextEntries, agentID: agent.processID, read: read)

        // A complete scan releases removed elements. Keep identities through partial scans.
        let knownProcesses = Set(applications.map(\.processID))
        let isComplete = read.isComplete && !windows.isEmpty && publishingProcessIDs.isSubset(of: knownProcesses)
        if isComplete {
            entries = nextEntries
        } else {
            let observed = Set(nextEntries.map(\.id))
            let running = Set(applications.map(\.processID))
            entries = nextEntries + entries.filter { !observed.contains($0.id) && running.contains($0.processID) }
        }
        return MenuBarAccessibilitySnapshot(
            items: (items + local.items).map { item in
                item.processID == agent.processID ? item : item.validatingFrame(hostedFrames: read.hostedFrames[item.processID, default: []])
            },
            isComplete: isComplete && local.isComplete,
            unavailableProcessIDs: read.unavailableProcessIDs.union(local.unavailableProcessIDs)
        )
    }

    private func reconcileNativeControls(items: inout [AccessibleMenuBarItem], entries nextEntries: inout [Entry], agentID: pid_t, read: ReadBudget) {
        // Wi-Fi replaces its AX wrapper after a drag on 27.0 (26A428), while
        // an old wrapper can still report its former frame. Resolve the live
        // control before checking order or updating section membership.
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        let displayStatus = CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount)
        if read.isComplete, displayStatus == .success {
            let hitIDs = Set(items.compactMap { item -> UUID? in
                guard
                    read.canContinue, item.processID == agentID, let frame = item.frame,
                    let entry = nextEntries.first(where: { $0.id == item.id }),
                    isHitElement(entry.element, frame: frame)
                else { return nil }
                return item.id
            })
            guard read.isComplete else { return }
            let resolved = AccessibleMenuBarItem.resolvingNativeControls(
                current: items,
                previous: nativeItems,
                hitItemIDs: hitIDs,
                displayBounds: displays.prefix(Int(displayCount)).map { CGDisplayBounds($0) }
            )
            let originalItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let originalEntries = Dictionary(nextEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            nextEntries = resolved.compactMap { resolution in
                guard let entry = originalEntries[resolution.elementID] else { return nil }
                return Entry(id: resolution.item.id, processID: entry.processID, element: entry.element)
            }
            // Keep the last known display for identity matching, but never
            // expose that old frame as current capture or input geometry.
            nativeItems = resolved.filter { $0.item.processID == agentID }.map { resolution in
                let item = resolution.item
                let frame = originalItems[resolution.elementID]?.frame ?? nativeItems.first(where: { $0.id == item.id })?.frame
                return AccessibleMenuBarItem(
                    id: item.id,
                    processID: item.processID,
                    bundleIdentifier: item.bundleIdentifier,
                    applicationName: item.applicationName,
                    accessibilityIdentifier: item.accessibilityIdentifier,
                    label: item.label,
                    frame: frame,
                    actions: item.actions
                )
            }
            let replacements = resolved.filter { $0.item.id != $0.elementID }.count
            if resolved.count != items.count || replacements > 0 {
                logger.debug("Resolved native menu bar controls: discarded \(items.count - resolved.count), replacements \(replacements)")
            }
            items = resolved.map(\.item)
        }
    }

    /// On macOS 26.5 (25F71), Control Center owns the status-item windows but
    /// each publisher's extras menu bar still supplies its own identity and
    /// geometry, including negative coordinates while hidden. Control Center
    /// has no hosting-window AX tree on this OS; query only extras menu bars.
    private func publisherSnapshot(applications: [Application], local: MenuBarAccessibilitySnapshot, discoverAllCandidates: Bool) -> MenuBarAccessibilitySnapshot {
        let running = Set(applications.map(\.processID))
        var publishers = Set(entries.map(\.processID)).intersection(running)
        if let controlCenter = applications.first(where: { $0.bundleIdentifier == "com.apple.controlcenter" }) {
            publishers.insert(controlCenter.processID)
        }
        discoverPublishers(applications: applications, known: &publishers, agentID: 0, discoverAllCandidates: discoverAllCandidates)
        let read = ReadBudget()
        var items = [AccessibleMenuBarItem]()
        var nextEntries = [Entry]()
        for application in applications where publishers.contains(application.processID) && application.processID != excludedProcessID {
            guard read.canContinue else { break }
            let app = AXUIElementCreateApplication(application.processID)
            if let extras = read.element(app, attribute: kAXExtrasMenuBarAttribute) {
                collect(extras, application: application, depth: 0, read: read, items: &items, entries: &nextEntries, publishers: &publishers)
            }
        }
        let complete = read.isComplete && local.isComplete
        if complete {
            entries = nextEntries
        } else {
            let observed = Set(nextEntries.map(\.id))
            entries = nextEntries + entries.filter { !observed.contains($0.id) && running.contains($0.processID) }
        }
        return MenuBarAccessibilitySnapshot(
            items: items + local.items,
            isComplete: complete,
            unavailableProcessIDs: read.unavailableProcessIDs.union(local.unavailableProcessIDs)
        )
    }

    /// Apps whose first item is already in overflow have no visible agent proxy.
    /// Probe just AXExtrasMenuBar, with a separate budget: a helper without an AX
    /// server must not invalidate the snapshot of established publishers.
    private func discoverPublishers(applications: [Application], known: inout Set<pid_t>, agentID: pid_t, discoverAllCandidates: Bool) {
        let candidates = publisherProbes.candidates(
            running: applications.filter { $0.processID > 0 && $0.processID != excludedProcessID && $0.processID != agentID }.map {
                MenuBarPublisherProbes.Process(id: $0.processID, launchDate: $0.launchDate)
            },
            knownPublishers: known,
            now: .now
        )
        // A panel's first image must not depend on the background scan reaching
        // the end of its startup backlog. Give explicit presentation one bounded
        // pass over eligible apps; leave periodic discovery limited to four.
        let budget = ReadBudget(duration: discoverAllCandidates ? .seconds(2) : .milliseconds(200))
        for process in candidates.prefix(discoverAllCandidates ? candidates.count : 4) {
            guard budget.canContinue else { break }
            publisherProbes.recordAttempt(process, now: .now)
            let app = AXUIElementCreateApplication(process.id)
            if budget.element(app, attribute: kAXExtrasMenuBarAttribute) != nil {
                known.insert(process.id)
                logger.debug("Found an extras menu bar outside the hosted tree for pid \(process.id)")
            }
        }
    }

    func localSnapshot(application: Application) -> MenuBarAccessibilitySnapshot {
        precondition(Thread.isMainThread)
        precondition(application.processID == ProcessInfo.processInfo.processIdentifier)
        let read = ReadBudget()
        var items = [AccessibleMenuBarItem]()
        var nextEntries = [Entry]()
        var publishers = Set<pid_t>()
        let app = AXUIElementCreateApplication(application.processID)
        if let extras = read.element(app, attribute: kAXExtrasMenuBarAttribute) {
            collect(extras, application: application, depth: 0, read: read, items: &items, entries: &nextEntries, publishers: &publishers)
        }
        if read.isComplete {
            entries = nextEntries
        }
        return MenuBarAccessibilitySnapshot(items: items, isComplete: read.isComplete, unavailableProcessIDs: read.unavailableProcessIDs)
    }

    /// Executes a supported semantic action on the current element, without window IDs.
    func performAction(itemID: UUID, showMenu: Bool) -> Bool {
        guard !Task.isCancelled, let entry = entries.first(where: { $0.id == itemID }) else { return false }
        let action = showMenu ? kAXShowMenuAction : kAXPressAction
        guard ReadBudget().actions(entry.element).contains(action) else { return false }
        AXUIElementSetMessagingTimeout(entry.element, 0.25)
        return AXUIElementPerformAction(entry.element, action as CFString) == .success
    }

    private func collect(
        _ element: AXUIElement,
        application: Application,
        depth: Int,
        read: ReadBudget,
        items: inout [AccessibleMenuBarItem],
        entries nextEntries: inout [Entry],
        publishers: inout Set<pid_t>,
        parentFrame: CGRect? = nil
    ) {
        // Check ownership before reading any attribute: even a role/frame read
        // on a local AX element may synchronously access an NSView hierarchy.
        guard let processID = read.processID(for: element) else { return }
        if processID == excludedProcessID {
            publishers.insert(processID)
            if let parentFrame { read.hostedFrames[processID, default: []].append(parentFrame) }
            return
        }
        guard read.visit(depth: depth) else { return }
        let role = read.string(element, attribute: kAXRoleAttribute)
        // Remote application proxies beneath MenuBarAgent are handled through their
        // own AXExtrasMenuBar above. Never descend into their windows or ordinary menus.
        if role == kAXApplicationRole {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success {
                publishers.insert(pid)
                if let parentFrame { read.hostedFrames[pid, default: []].append(parentFrame) }
            }
            return
        }
        // macOS 27 exposes both direct remote buttons and application proxies in
        // separate agent windows. Record only their hosted geometry, not app UI.
        if role == kAXButtonRole {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, pid != application.processID {
                publishers.insert(pid)
                if let frame = read.frame(element) { read.hostedFrames[pid, default: []].append(frame) }
                return
            }
        }
        guard role != kAXMenuRole else { return }

        if role == kAXMenuBarItemRole {
            if nextEntries.contains(where: { CFEqual($0.element, element) }) { return }
            let id = entries.first(where: { $0.processID == application.processID && CFEqual($0.element, element) })?.id ?? UUID()
            let identifier = read.string(element, attribute: kAXIdentifierAttribute)
            let label = read.string(element, attribute: kAXDescriptionAttribute) ?? read.string(element, attribute: kAXTitleAttribute)
            let frame = read.frame(element)
            let actions = read.actions(element)
            guard read.canContinue else { return }
            let item = AccessibleMenuBarItem(
                id: id,
                processID: application.processID,
                bundleIdentifier: application.bundleIdentifier,
                applicationName: application.name,
                accessibilityIdentifier: identifier,
                label: label,
                frame: frame,
                actions: actions
            )
            // Verified on 27.0 (26A428): native controls appear under multiple
            // agent windows with distinct handles but identical IDs and bounds.
            if application.bundleIdentifier != "com.apple.MenuBarAgent", items.contains(where: { $0.representsSameControl(as: item) }) { return }
            nextEntries.append(Entry(id: id, processID: application.processID, element: element))
            items.append(item)
            return
        }

        let hostFrame = depth == 1 ? read.frame(element) : nil
        for child in read.children(element) {
            collect(child, application: application, depth: depth + 1, read: read, items: &items, entries: &nextEntries, publishers: &publishers, parentFrame: hostFrame)
        }
    }
}

private extension MenuBarAccessibilityReader {
    /// One scan has a wall-clock budget in addition to per-message AX timeouts.
    /// Each scan stays with its reader's owner; its counters never cross actors.
    final class ReadBudget {
        private let deadline: ContinuousClock.Instant
        private let checksCancellation: Bool
        private var visits = 0
        private var wasTruncated = false
        private(set) var unavailableProcessIDs = Set<pid_t>()
        var hostedFrames = [pid_t: [CGRect]]()

        init(duration: Duration = .seconds(2), checksCancellation: Bool = true) {
            deadline = .now.advanced(by: duration)
            self.checksCancellation = checksCancellation
        }

        var canContinue: Bool {
            if (checksCancellation && Task.isCancelled) || ContinuousClock.now >= deadline {
                wasTruncated = true
                return false
            }
            return true
        }

        var isComplete: Bool {
            canContinue && !wasTruncated && unavailableProcessIDs.isEmpty
        }

        func visit(depth: Int) -> Bool {
            guard canContinue else { return false }
            guard depth <= 6, visits < 512 else {
                wasTruncated = true
                return false
            }
            visits += 1
            return true
        }

        private func assertLocalAccessIsOnMainThread(_ element: AXUIElement) {
            var processID: pid_t = 0
            if AXUIElementGetPid(element, &processID) == .success, processID == ProcessInfo.processInfo.processIdentifier {
                precondition(Thread.isMainThread, "Local Accessibility access must stay on the main thread")
            }
        }

        func processID(for element: AXUIElement) -> pid_t? {
            var processID: pid_t = 0
            let error = AXUIElementGetPid(element, &processID)
            record(error, element: element)
            return error == .success ? processID : nil
        }

        private func record(_ error: AXError, element: AXUIElement) {
            switch error {
            case .success, .attributeUnsupported, .noValue, .actionUnsupported:
                break
            default:
                var pid: pid_t = 0
                if AXUIElementGetPid(element, &pid) == .success {
                    unavailableProcessIDs.insert(pid)
                } else {
                    wasTruncated = true
                }
            }
        }

        func value(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
            assertLocalAccessIsOnMainThread(element)
            guard canContinue else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            record(error, element: element)
            return error == .success ? value : nil
        }

        func string(_ element: AXUIElement, attribute: String) -> String? {
            value(element, attribute: attribute) as? String
        }

        func element(_ parent: AXUIElement, attribute: String) -> AXUIElement? {
            guard let value = value(parent, attribute: attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            // CF's runtime type was checked above; a conditional CF downcast is not supported.
            return unsafeDowncast(value, to: AXUIElement.self)
        }

        func children(_ element: AXUIElement, attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
            value(element, attribute: attribute) as? [AXUIElement] ?? []
        }

        func frame(_ element: AXUIElement) -> CGRect? {
            guard
                let position = value(element, attribute: kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                let size = value(element, attribute: kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            let positionValue = unsafeDowncast(position, to: AXValue.self)
            let sizeValue = unsafeDowncast(size, to: AXValue.self)
            guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(positionValue, .cgPoint, &origin), AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
            return AccessibleMenuBarItem.validFrame(origin: origin, size: dimensions)
        }

        func isRetainedMenuBarItem(_ element: AXUIElement) -> Bool {
            guard canContinue else { return false }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if error == .invalidUIElement { return false }
            record(error, element: element)
            return error == .success && role as? String == kAXMenuBarItemRole
        }

        func actions(_ element: AXUIElement) -> [String] {
            assertLocalAccessIsOnMainThread(element)
            guard canContinue else { return [] }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var names: CFArray?
            let error = AXUIElementCopyActionNames(element, &names)
            record(error, element: element)
            return error == .success ? names as? [String] ?? [] : []
        }
    }
}
