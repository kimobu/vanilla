//
//  ColorPickerTests.swift
//  Ice
//

import SwiftUI
import Testing

@MainActor
struct ColorPickerTests {
    @MainActor
    private final class Selection {
        var color: CGColor = NSColor.black.cgColor

        var binding: Binding<CGColor> {
            Binding(get: { self.color }, set: { self.color = $0 })
        }
    }

    @Test func programmaticUpdatesDoNotWriteBackButUserActionsDo() {
        _ = NSApplication.shared
        let selection = Selection()
        let original = selection.color
        let coordinator = CustomColorPicker.Coordinator(selection: selection.binding, supportsOpacity: true, mode: .crayon)
        let well = NSColorWell()
        coordinator.configure(with: well)
        defer { coordinator.tearDown(well) }
        well.color = .red
        #expect(selection.color == original)
        #expect(well.sendAction(well.action, to: well.target))
        #expect(selection.color == NSColor.red.cgColor)
    }

    @Test func reusedWellEditsCurrentBindingAndTeardownDisconnectsIt() {
        _ = NSApplication.shared
        let old = Selection()
        let current = Selection()
        let original = old.color
        let coordinator = CustomColorPicker.Coordinator(selection: old.binding, supportsOpacity: false, mode: .crayon)
        let well = NSColorWell()
        coordinator.configure(with: well)
        coordinator.update(selection: current.binding, supportsOpacity: true, mode: .RGB)
        well.color = .blue
        #expect(well.sendAction(well.action, to: well.target))
        #expect(old.color == original)
        #expect(current.color == NSColor.blue.cgColor)
        #expect(coordinator.supportsOpacity)
        #expect(coordinator.mode == .RGB)
        coordinator.tearDown(well)
        #expect(well.target == nil)
        #expect(well.action == nil)
    }
}
