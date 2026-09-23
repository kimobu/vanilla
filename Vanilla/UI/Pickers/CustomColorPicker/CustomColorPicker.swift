//
//  CustomColorPicker.swift
//  Ice
//

import Combine
import SwiftUI

struct CustomColorPicker: NSViewRepresentable {
    @MainActor
    final class Coordinator: NSObject {
        @Binding var selection: CGColor

        var supportsOpacity: Bool
        var mode: NSColorPanel.Mode

        private var cancellables = Set<AnyCancellable>()

        init(
            selection: Binding<CGColor>,
            supportsOpacity: Bool,
            mode: NSColorPanel.Mode
        ) {
            self._selection = selection
            self.supportsOpacity = supportsOpacity
            self.mode = mode
            super.init()
        }

        @objc private func colorDidChange(_ sender: NSColorWell) {
            if selection != sender.color.cgColor {
                selection = sender.color.cgColor
            }
        }

        func update(selection: Binding<CGColor>, supportsOpacity: Bool, mode: NSColorPanel.Mode) {
            self._selection = selection
            self.supportsOpacity = supportsOpacity
            self.mode = mode
        }

        func configure(with nsView: NSColorWell) {
            var c = Set<AnyCancellable>()

            // Only user edits send an action. A SwiftUI update that assigns the
            // well's color must not enqueue a write back into an older binding.
            nsView.target = self
            nsView.action = #selector(colorDidChange(_:))

            NSColorPanel.shared
                .publisher(for: \.isVisible)
                .sink { [weak self, weak nsView] isVisible in
                    guard
                        let self,
                        let nsView,
                        isVisible,
                        nsView.isActive
                    else {
                        return
                    }
                    NSColorPanel.shared.showsAlpha = supportsOpacity
                    NSColorPanel.shared.mode = mode
                    if let window = nsView.window {
                        NSColorPanel.shared.level = window.level + 1
                    }
                    if NSColorPanel.shared.frame.origin == .zero {
                        NSColorPanel.shared.center()
                    }
                }
                .store(in: &c)

            NSColorPanel.shared
                .publisher(for: \.level)
                .sink { [weak nsView] level in
                    guard
                        let nsView,
                        nsView.isActive,
                        let window = nsView.window,
                        level != window.level + 1
                    else {
                        return
                    }
                    NSColorPanel.shared.level = window.level + 1
                }
                .store(in: &c)

            cancellables = c
        }

        func tearDown(_ nsView: NSColorWell) {
            cancellables.removeAll()
            nsView.target = nil
            nsView.action = nil
            if nsView.isActive { nsView.deactivate() }
        }
    }

    let label: String
    @Binding var selection: CGColor

    let supportsOpacity: Bool
    let mode: NSColorPanel.Mode

    func makeNSView(context: Context) -> NSColorWell {
        let nsView = NSColorWell()
        nsView.setAccessibilityLabel(label)
        context.coordinator.configure(with: nsView)
        return nsView
    }

    func updateNSView(_ nsView: NSColorWell, context: Context) {
        nsView.setAccessibilityLabel(label)
        context.coordinator.update(selection: $selection, supportsOpacity: supportsOpacity, mode: mode)
        if let color = NSColor(cgColor: selection) {
            nsView.color = color
        }
        nsView.supportsAlpha = supportsOpacity
    }

    static func dismantleNSView(_ nsView: NSColorWell, coordinator: Coordinator) {
        coordinator.tearDown(nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: $selection,
            supportsOpacity: supportsOpacity,
            mode: mode
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSColorWell,
        context: Context
    ) -> CGSize? {
        switch nsView.controlSize {
        case .extraLarge:
            nsView.intrinsicContentSize
        case .large:
            CGSize(width: 55, height: 30)
        case .regular:
            CGSize(width: 44, height: 24)
        case .small:
            CGSize(width: 33, height: 18)
        case .mini:
            CGSize(width: 29, height: 16)
        @unknown default:
            nsView.intrinsicContentSize
        }
    }
}
