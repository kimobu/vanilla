//
//  LayoutBarPaddingView.swift
//  Ice
//

import Cocoa
import Combine

/// A Cocoa view that manages the menu bar layout interface.
final class LayoutBarPaddingView: NSView {
    private let container: LayoutBarContainer
    private var moveTask: Task<Void, Never>?

    /// The section whose items are represented.
    var section: MenuBarSection {
        container.section
    }

    /// The amount of space between each arranged view.
    var spacing: CGFloat {
        get { container.spacing }
        set { container.spacing = newValue }
    }

    /// The layout view's arranged views.
    ///
    /// The views are laid out from left to right in the order that they
    /// appear in the array. The ``spacing`` property determines the amount
    /// of space between each view.
    var arrangedViews: [LayoutBarItemView] {
        get { container.arrangedViews }
        set { container.arrangedViews = newValue }
    }

    /// Creates a layout bar view with the given app state, section, and spacing.
    ///
    /// - Parameters:
    ///   - appState: The shared app state instance.
    ///   - section: The section whose items are represented.
    ///   - spacing: The amount of space between each arranged view.
    init(appState: AppState, section: MenuBarSection, spacing: CGFloat) {
        self.container = LayoutBarContainer(appState: appState, section: section, spacing: spacing)

        super.init(frame: .zero)
        addSubview(self.container)

        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // center the container along the y axis
            container.centerYAnchor.constraint(equalTo: centerYAnchor),

            // give the container a few points of trailing space
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 7.5),

            // allow variable spacing between leading anchors to let the view stretch
            // to fit whatever size is required; container should remain aligned toward
            // the trailing edge; this view is itself nested in a scroll view, so if it
            // has to expand to a larger size, it can be clipped
            leadingAnchor.constraint(lessThanOrEqualTo: container.leadingAnchor, constant: -7.5),
        ])

        registerForDraggedTypes([.layoutBarItem])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        moveTask?.cancel()
    }

    /// Reorders one step within this section for assistive technology users.
    func moveAdjacent(_ view: LayoutBarItemView, offset: Int) -> Bool {
        guard
            offset == -1 || offset == 1,
            moveTask == nil,
            container.canSetArrangedViews,
            container.appState != nil,
            view.isEnabled,
            let index = arrangedViews.firstIndex(of: view),
            arrangedViews.indices.contains(index + offset),
            arrangedViews[index + offset].isEnabled
        else { return false }
        let target = arrangedViews[index + offset].item
        move(item: view.item, to: offset < 0 ? .leftOfItem(target) : .rightOfItem(target))
        return true
    }

    func moveToSection(_ view: LayoutBarItemView, name: MenuBarSection.Name) -> Bool {
        guard
            moveTask == nil,
            container.canSetArrangedViews,
            view.isEnabled,
            arrangedViews.contains(view),
            name != section.name,
            name == .visible || view.item.canBeHidden,
            let destination = container.appState?.itemManager.movementDestination(for: name)
        else { return false }
        move(item: view.item, to: destination)
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        container.updateArrangedViewsForDrag(with: sender, phase: .entered)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender {
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        container.updateArrangedViewsForDrag(with: sender, phase: .updated)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        container.updateArrangedViewsForDrag(with: sender, phase: .ended)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // A fast drag may reach its final position between draggingUpdated callbacks.
        container.updateArrangedViewsForDrag(with: sender, phase: .updated)
        guard let draggingSource = sender.draggingSource as? LayoutBarItemView else {
            return false
        }

        if let index = arrangedViews.firstIndex(of: draggingSource) {
            if arrangedViews.count == 1 {
                // dragging source is the only view in the layout bar, so we
                // need to find a target item
                if let destination = container.appState?.itemManager.movementDestination(for: section.name) {
                    move(item: draggingSource.item, to: destination)
                } else {
                    Logger.layoutBar.error("No target item for layout bar drag")
                }
            } else if arrangedViews.indices.contains(index + 1) {
                // we have a view to the right of the dragging source
                let targetItem = arrangedViews[index + 1].item
                move(item: draggingSource.item, to: .leftOfItem(targetItem))
            } else if arrangedViews.indices.contains(index - 1) {
                // we have a view to the left of the dragging source
                let targetItem = arrangedViews[index - 1].item
                move(item: draggingSource.item, to: .rightOfItem(targetItem))
            }
        }

        return true
    }

    private func move(item: MenuBarItem, to destination: MenuBarItemManager.MoveDestination) {
        guard moveTask == nil, let appState = container.appState else {
            return
        }
        moveTask = Task { [weak self] in
            defer { self?.moveTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(25))
                try await appState.itemManager.slowMove(item: item, to: destination)
                appState.itemManager.removeTempShownItemFromCache(with: item.info)
                // Moving into a collapsed section invalidates its screen bounds.
                // Refresh after placement so Layout does not retain an image of
                // the previous position or require reopening the pane.
                await appState.itemManager.refreshImagesForPresentation()
            } catch is CancellationError {
                return
            } catch {
                Logger.layoutBar.error("Error moving menu bar item: \(error)")
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let layoutBar = Logger(category: "LayoutBar")
}
