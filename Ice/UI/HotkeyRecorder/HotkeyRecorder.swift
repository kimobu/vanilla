//
//  HotkeyRecorder.swift
//  Ice
//

import SwiftUI

struct HotkeyRecorder<Label: View>: View {
    @StateObject private var model: HotkeyRecorderModel

    private let label: Label

    private var shortcutDescription: String {
        if model.isRecording { return String(localized: "Recording") }
        guard let combination = model.hotkey.keyCombination else { return String(localized: "Not set") }
        return combination.modifiers.symbolicValue + combination.key.stringValue.capitalized
    }

    init(hotkey: Hotkey, @ViewBuilder label: () -> Label) {
        self._model = StateObject(wrappedValue: HotkeyRecorderModel(hotkey: hotkey))
        self.label = label()
    }

    var body: some View {
        HStack(alignment: .center) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            HStack(spacing: 1) {
                leadingSegment
                trailingSegment
            }
            .frame(width: 132, height: 24)
        }
        .accessibilityElement(children: .contain)
        .alert(
            "Hotkey is reserved by macOS",
            isPresented: $model.isPresentingReservedByMacOSError
        ) {
            Button("OK") {
                model.isPresentingReservedByMacOSError = false
            }
        }
        .onDisappear { model.stopRecording() }
    }

    @ViewBuilder
    private var leadingSegment: some View {
        Button {
            model.startRecording()
        } label: {
            leadingSegmentLabel
        }
        .accessibilityLabel { _ in label }
        .accessibilityValue(shortcutDescription)
        .accessibilityHint(model.isRecording ? "Type a shortcut, or press Escape to cancel" : "Record a keyboard shortcut")
        .buttonStyle(
            HotkeyRecorderSegmentButtonStyle(
                segment: .leading,
                isHighlighted: model.isRecording
            )
        )
    }

    @ViewBuilder
    private var trailingSegment: some View {
        Button {
            if model.isRecording {
                model.stopRecording()
            } else if model.hotkey.isEnabled {
                model.hotkey.keyCombination = nil
            } else {
                model.startRecording()
            }
        } label: {
            trailingSegmentLabel
        }
        .buttonStyle(
            HotkeyRecorderSegmentButtonStyle(
                segment: .trailing,
                isHighlighted: false
            )
        )
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(model.isRecording ? "Cancel recording" : model.hotkey.isEnabled ? "Clear shortcut" : "Record shortcut")
    }

    @ViewBuilder
    private var leadingSegmentLabel: some View {
        if model.isRecording {
            Text("Type Hotkey")
        } else if model.hotkey.isEnabled {
            if let keyCombination = model.hotkey.keyCombination {
                HStack(spacing: 0) {
                    Text(keyCombination.modifiers.symbolicValue)
                    Text(keyCombination.key.stringValue.capitalized)
                }
            } else {
                Text("ERROR")
            }
        } else {
            Text("Record Hotkey")
        }
    }

    @ViewBuilder
    private var trailingSegmentLabel: some View {
        let symbolString = if model.isRecording {
            "escape"
        } else if model.hotkey.isEnabled {
            "xmark.circle.fill"
        } else {
            "record.circle"
        }
        Image(systemName: symbolString)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .padding(2)
    }
}

private struct HotkeyRecorderSegmentButtonStyle: ButtonStyle {
    enum Segment {
        case leading
        case trailing
    }

    var segment: Segment
    var isHighlighted: Bool

    private var radii: RectangleCornerRadii {
        switch segment {
        case .leading:
            RectangleCornerRadii(topLeading: 5, bottomLeading: 5)
        case .trailing:
            RectangleCornerRadii(bottomTrailing: 5, topTrailing: 5)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                UnevenRoundedRectangle(cornerRadii: radii, style: .circular)
                    .fill(isHighlighted || configuration.isPressed ? .tertiary : .quaternary)
            }
            .contentShape(Rectangle())
    }
}
