//
//  IceSlider.swift
//  Ice
//

import CompactSlider
import SwiftUI

struct IceSlider<Value: BinaryFloatingPoint, ValueLabel: View, ValueLabelSelectability: TextSelectability>: View {
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    // On macOS 26, a retained key callback can read an older functional
    // Binding value. State provides a live location across callback reuse;
    // onChange below also follows pointer, accessibility, and external edits.
    // Reproduction and verification: docs/audits/2026-09-20-slider-state.txt.
    @State private var keyboardValue: Value

    private let accessibilityLabel: LocalizedStringKey
    private let value: Binding<Value>
    private let bounds: ClosedRange<Value>
    private let step: Value
    private let valueLabel: ValueLabel
    private let valueLabelSelectability: ValueLabelSelectability

    init(
        accessibilityLabel: LocalizedStringKey,
        value: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0,
        valueLabelSelectability: ValueLabelSelectability = .disabled,
        @ViewBuilder valueLabel: () -> ValueLabel
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.value = value
        self._keyboardValue = State(initialValue: value.wrappedValue)
        self.bounds = bounds
        self.step = step
        self.valueLabel = valueLabel()
        self.valueLabelSelectability = valueLabelSelectability
    }

    init(
        _ valueLabelKey: LocalizedStringKey,
        accessibilityLabel: LocalizedStringKey,
        valueLabelSelectability: ValueLabelSelectability = .disabled,
        value: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0
    ) where ValueLabel == Text {
        self.init(
            accessibilityLabel: accessibilityLabel,
            value: value,
            in: bounds,
            step: step,
            valueLabelSelectability: valueLabelSelectability
        ) {
            Text(valueLabelKey)
        }
    }

    var body: some View {
        CompactSlider(value: value, in: bounds, step: step)
            .compactSliderHandleStyle(.rectangle(visibility: .focused, width: 1))
            .compactSliderOptionsByRemoving(.enabledHapticFeedback)
            .frame(minHeight: 24)
            .overlay {
                valueLabel
                    .textSelection(valueLabelSelectability)
                    .padding(.horizontal, 6)
                    // Nonselectable labels must let drags reach the slider below.
                    .allowsHitTesting(ValueLabelSelectability.allowsSelection)
            }
            .focusable(isEnabled, interactions: .edit)
            .focused($isFocused)
            .simultaneousGesture(TapGesture().onEnded { isFocused = true })
            .onKeyPress(keys: [.leftArrow, .rightArrow, .downArrow, .upArrow]) { press in
                guard isEnabled else { return .ignored }
                let increment = step > 0 ? step : (bounds.upperBound - bounds.lowerBound) / 100
                let direction: Value = press.key == .leftArrow || press.key == .downArrow ? -1 : 1
                let proposed = keyboardValue + direction * increment
                let snapped = step > 0 ? bounds.lowerBound + ((proposed - bounds.lowerBound) / step).rounded() * step : proposed
                let newValue = min(bounds.upperBound, max(bounds.lowerBound, snapped))
                keyboardValue = newValue
                value.wrappedValue = newValue
                return .handled
            }
            .onChange(of: value.wrappedValue) { _, newValue in
                keyboardValue = newValue
            }
            // Retain the compact drawing while exposing a real adjustable slider
            // to assistive technologies, including its label, bounds, and step.
            .accessibilityRepresentation {
                Slider(
                    value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Value($0) }),
                    in: Double(bounds.lowerBound)...Double(bounds.upperBound),
                    step: Double(step > 0 ? step : (bounds.upperBound - bounds.lowerBound) / 100)
                ) {
                    Text(accessibilityLabel)
                }
                .accessibilityValue(Text(Double(value.wrappedValue), format: .number))
            }
    }
}
