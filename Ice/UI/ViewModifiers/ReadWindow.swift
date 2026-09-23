//
//  ReadWindow.swift
//  Ice
//

import SwiftUI

private struct WindowReader: NSViewRepresentable {
    final class ReaderView: NSView {
        var onWindowChange: (@MainActor (NSWindow?) -> Void)?
        private var deliveryTask: Task<Void, Never>?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            deliveryTask?.cancel()
            // Deliver after AppKit's update so bindings are not mutated during a SwiftUI render.
            deliveryTask = Task { [weak self] in
                guard !Task.isCancelled, let self else { return }
                onWindowChange?(window)
            }
        }

        func stop() {
            deliveryTask?.cancel()
            deliveryTask = nil
            onWindowChange = nil
        }
    }

    let onWindowChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindowChange = onWindowChange
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        view.stop()
    }
}

extension View {
    /// Reads the window of this view, performing the given closure when
    /// the window changes.
    ///
    /// - Parameter onChange: A closure to perform when the window changes.
    func readWindow(onChange: @MainActor @escaping (_ window: NSWindow?) -> Void) -> some View {
        background {
            WindowReader(onWindowChange: onChange)
        }
    }

    /// Reads the window of this view, assigning it to the given binding.
    ///
    /// - Parameter window: A binding to use to store the view's window.
    func readWindow(window: Binding<NSWindow?>) -> some View {
        readWindow { window.wrappedValue = $0 }
    }
}
