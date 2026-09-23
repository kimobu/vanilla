//
//  LayoutBarItemView.swift
//  Ice
//

import Cocoa
import Combine

// MARK: - LayoutBarItemView

/// A view that displays an image in a menu bar layout view.
final class LayoutBarItemView: NSView {
    private weak var appState: AppState?

    private var cancellables = Set<AnyCancellable>()
    private let dragContainers = NSHashTable<LayoutBarContainer>.weakObjects()
    private var isDragging = false

    /// The item that the view represents.
    let item: MenuBarItem

    /// The original row and index, retained until the dragging session ends.
    /// Other rows use this to distinguish insertion from movement within a row.
    var oldContainerInfo: (container: LayoutBarContainer, index: Int)?

    /// Cache updates must not replace a placeholder in any row visited by this drag.
    func holdLayoutUpdates(in container: LayoutBarContainer) {
        container.canSetArrangedViews = false
        dragContainers.add(container)
    }

    /// A Boolean value that indicates whether the item view is currently inside a container.
    var hasContainer = false

    /// The image displayed inside the view.
    private var image: NSImage? {
        didSet {
            if let image {
                setFrameSize(image.size)
            } else {
                setFrameSize(.zero)
            }
            needsDisplay = true
        }
    }

    /// A Boolean value that indicates whether the item view is a dragging placeholder.
    ///
    /// If this value is `true`, the item view does not draw its image.
    var isDraggingPlaceholder = false {
        didSet {
            needsDisplay = true
        }
    }

    /// A Boolean value that indicates whether the view is enabled.
    var isEnabled = true {
        didSet {
            needsDisplay = true
        }
    }

    /// Creates a view that displays the given menu bar item.
    init(appState: AppState, item: MenuBarItem) {
        self.item = item
        self.appState = appState

        // set the frame to the full item frame size; the image will be centered when displayed
        super.init(frame: CGRect(origin: .zero, size: item.frame.size))
        unregisterDraggedTypes()

        self.toolTip = item.displayName
        self.isEnabled = item.isMovable
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(item.displayName)

        configureCancellables()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard
            isEnabled,
            let container = superview as? LayoutBarContainer,
            container.canSetArrangedViews,
            let index = container.arrangedViews.firstIndex(of: self)
        else { return nil }
        var actions = [NSAccessibilityCustomAction]()
        if index > 0, container.arrangedViews[index - 1].isEnabled {
            actions.append(NSAccessibilityCustomAction(name: "Move Left", target: self, selector: #selector(accessibilityMoveLeft(_:))))
        }
        if index + 1 < container.arrangedViews.count, container.arrangedViews[index + 1].isEnabled {
            actions.append(NSAccessibilityCustomAction(name: "Move Right", target: self, selector: #selector(accessibilityMoveRight(_:))))
        }
        if let appState {
            for section in appState.menuBarManager.sections where section.isEnabled && section.name != container.section.name {
                guard section.name == .visible || item.canBeHidden else { continue }
                let selector = switch section.name {
                case .visible: #selector(accessibilityMoveToVisible(_:))
                case .hidden: #selector(accessibilityMoveToHidden(_:))
                case .alwaysHidden: #selector(accessibilityMoveToAlwaysHidden(_:))
                }
                actions.append(NSAccessibilityCustomAction(name: "Move to \(section.name.displayString)", target: self, selector: selector))
            }
        }
        return actions
    }

    @objc private func accessibilityMoveToVisible(_ action: NSAccessibilityCustomAction) -> Bool {
        (superview?.superview as? LayoutBarPaddingView)?.moveToSection(self, name: .visible) ?? false
    }

    @objc private func accessibilityMoveToHidden(_ action: NSAccessibilityCustomAction) -> Bool {
        (superview?.superview as? LayoutBarPaddingView)?.moveToSection(self, name: .hidden) ?? false
    }

    @objc private func accessibilityMoveToAlwaysHidden(_ action: NSAccessibilityCustomAction) -> Bool {
        (superview?.superview as? LayoutBarPaddingView)?.moveToSection(self, name: .alwaysHidden) ?? false
    }

    @objc private func accessibilityMoveLeft(_ action: NSAccessibilityCustomAction) -> Bool {
        (superview?.superview as? LayoutBarPaddingView)?.moveAdjacent(self, offset: -1) ?? false
    }

    @objc private func accessibilityMoveRight(_ action: NSAccessibilityCustomAction) -> Bool {
        (superview?.superview as? LayoutBarPaddingView)?.moveAdjacent(self, offset: 1) ?? false
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            appState.imageCache.$images
                .sink { [weak self] images in
                    guard
                        let self,
                        let capture = images[item.info]
                    else {
                        return
                    }
                    image = capture.nsImage
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Provides an alert to display when the item view is disabled.
    func provideAlertForDisabledItem() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Menu bar item is not movable."
        alert.informativeText = "macOS prohibits \"\(item.displayName)\" from being moved."
        return alert
    }

    /// Provides an alert to display when a menu bar item is unresponsive.
    func provideAlertForUnresponsiveItem() -> NSAlert {
        let alert = provideAlertForDisabledItem()
        alert.informativeText = "\(item.displayName) is unresponsive. Until it is restarted, it cannot be moved. Movement of other menu bar items may also be affected until this is resolved."
        return alert
    }

    override func draw(_ dirtyRect: NSRect) {
        if !isDraggingPlaceholder {
            image?.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: isEnabled ? 1.0 : 0.67
            )
            if Bridging.responsivity(for: item.ownerPID) == .unresponsive {
                let warningImage = NSImage.warning
                let width: CGFloat = 15
                let scale = width / warningImage.size.width
                let size = CGSize(
                    width: width,
                    height: warningImage.size.height * scale
                )
                warningImage.draw(
                    in: CGRect(
                        x: bounds.maxX - size.width,
                        y: bounds.minY,
                        width: size.width,
                        height: size.height
                    )
                )
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)

        guard isEnabled else {
            let alert = provideAlertForDisabledItem()
            alert.runModal()
            return
        }

        guard Bridging.responsivity(for: item.ownerPID) != .unresponsive else {
            let alert = provideAlertForUnresponsiveItem()
            alert.runModal()
            return
        }

        let pasteboardItem = NSPasteboardItem()
        // contents of the pasteboard item don't matter here, as all needed information
        // is available directly from the dragging session; what matters is that the type
        // is set to `layoutBarItem`, as that is what the layout bar registers for
        pasteboardItem.setData(Data(), forType: .layoutBarItem)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: image)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
}

// MARK: LayoutBarItemView: NSDraggingSource
extension LayoutBarItemView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        isDragging = true
        // make sure the container doesn't update its arranged views and that items
        // aren't arranged during a dragging session
        if let container = superview as? LayoutBarContainer {
            holdLayoutUpdates(in: container)
            if let index = container.arrangedViews.firstIndex(of: self) {
                oldContainerInfo = (container, index)
            }
        }

        // prevent the dragging image from animating back to its original location
        session.animatesToStartingPositionsOnCancelOrFail = false

        // async to prevent the view from disappearing before the dragging image appears
        DispatchQueue.main.async { [weak self] in
            guard let self, isDragging else { return }
            isDraggingPlaceholder = true
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        defer {
            // Restore every visited row, including one left before cancellation.
            for container in dragContainers.allObjects {
                container.canSetArrangedViews = true
                if operation.isEmpty {
                    // Use current model state, which also excludes a publisher
                    // that exited while its image was being dragged.
                    container.setArrangedViews(items: appState?.itemManager.itemCache.managedItems(for: container.section.name))
                }
            }
            dragContainers.removeAllObjects()
            oldContainerInfo = nil
        }

        // since the session's `animatesToStartingPositionsOnCancelOrFail` property was
        // set to false when the session began (above), there is no delay between the user
        // releasing the dragging item and this method being called; thus, `isDraggingPlaceholder`
        // only needs to be updated here; if we ever decide we want animation, it may also
        // need to be updated inside `performDragOperation(_:)` on `LayoutBarPaddingView`
        isDraggingPlaceholder = false

        // A successful drop without an attached destination retains the original
        // view until the resulting model update arrives. Cancellation instead
        // reconciles every visited row with the current cache in the defer above.
        if !hasContainer && !operation.isEmpty {
            guard let (container, index) = oldContainerInfo else {
                return
            }
            container.shouldAnimateNextLayoutPass = false
            container.arrangedViews.insert(self, at: min(index, container.arrangedViews.count))
        }
    }
}

extension LayoutBarItemView: @MainActor NSAccessibilityLayoutItem { }

// MARK: Layout Bar Item Pasteboard Type
extension NSPasteboard.PasteboardType {
    static let layoutBarItem = Self("\(Constants.bundleIdentifier).layout-bar-item")
}
