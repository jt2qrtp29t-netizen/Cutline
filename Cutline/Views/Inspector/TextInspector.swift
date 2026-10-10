import AppKit
import SwiftUI

/// Text Adjustments: content, font, size, color, position, opacity and stroke of a text clip.
struct TextInspector: View {
    let editor: EditorController
    let clip: Clip
    let text: TextStyle

    @State private var draft = ""
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if clip.isLocked {
                Label("This clip is locked. Unlock it from its right-click menu to edit.", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            Group {
                InspectorSection(title: "Text") {
                    TextEditor(text: $draft)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($textFocused)
                        .padding(6)
                        .frame(height: 80)
                        .background(Theme.recessed, in: .rect(cornerRadius: Theme.Metrics.controlCornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius).strokeBorder(Theme.border))
                    HStack {
                        Text("Return adds a new line.")
                        Spacer()
                        Text("\(draft.count)/\(TextStyle.maximumLength)")
                            .foregroundStyle(draft.count >= TextStyle.maximumLength ? Theme.destructive : Theme.textTertiary)
                            .monospacedDigit()
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                }

                InspectorSection(title: "Font") {
                    FontPicker(postScriptName: text.fontName) { name in
                        update("Change Font") { $0.fontName = name }
                    }
                    textSlider("Size", \.size, range: 8...800, unit: "px", unitsPerPoint: 0.5, action: "Change Text Size")
                    ColorRow(title: "Color", color: text.color) { color in
                        update("Change Text Color", coalesce: true) { $0.color = color }
                    }
                }

                InspectorSection(title: "Position", onReset: {
                    editor.adjustClip(clip.id, actionName: "Reset Position") { clip in
                        clip.transform.positionX = 0
                        clip.transform.positionY = 0
                        clip.transform.endPositionX = nil
                        clip.transform.endPositionY = nil
                    }
                }) {
                    positionRow("X", start: \.transform.positionX, end: \.transform.endPositionX,
                                limit: Double(editor.settings.width))
                    positionRow("Y", start: \.transform.positionY, end: \.transform.endPositionY,
                                limit: Double(editor.settings.height))
                    clipSlider("Opacity", \.opacity, range: 0...1, displayScale: 100, unit: "%", action: "Change Opacity")
                    Text("0 / 0 is the center of the frame. Unlock 🔒 to move the text over the clip's duration.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                InspectorSection(title: "Stroke") {
                    Toggle("Stroke", isOn: Binding(
                        get: { text.strokeEnabled },
                        set: { enabled in update(enabled ? "Add Stroke" : "Remove Stroke") { $0.strokeEnabled = enabled } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

                    if text.strokeEnabled {
                        Picker("Position", selection: Binding(
                            get: { text.strokePosition },
                            set: { position in update("Change Stroke Position") { $0.strokePosition = position } }
                        )) {
                            ForEach(StrokePosition.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        textSlider("Width", \.strokeWidth, range: 0.5...80, unit: "px", fractionDigits: 1,
                                   unitsPerPoint: 0.1, action: "Change Stroke Width")
                        ColorRow(title: "Color", color: text.strokeColor) { color in
                            update("Change Stroke Color", coalesce: true) { $0.strokeColor = color }
                        }
                    }
                }
            }
            .disabled(clip.isLocked)

            InspectorSection(title: "Timing") {
                InspectorValueRow(title: "Start", value: Timecode.string(for: clip.start, fps: editor.fps, alwaysShowHours: true))
                InspectorValueRow(title: "Duration", value: Timecode.string(for: clip.duration, fps: editor.fps, alwaysShowHours: true))
            }
        }
        .onAppear {
            draft = text.string
            focusIfRequested()
        }
        .onChange(of: editor.pendingTextFocus) { focusIfRequested() }
        .onChange(of: draft) { _, newValue in
            let limited = String(newValue.prefix(TextStyle.maximumLength))
            if limited != newValue { draft = limited; return }
            if limited != text.string {
                update("Edit Text", coalesce: true) { $0.string = limited }
            }
        }
        .onChange(of: text.string) { _, newValue in
            if !textFocused && newValue != draft { draft = newValue }
        }
    }

    /// A newly added text clip focuses the text field with everything selected,
    /// so typing replaces the placeholder.
    private func focusIfRequested() {
        guard editor.pendingTextFocus == clip.id else { return }
        editor.pendingTextFocus = nil
        Task { @MainActor in
            textFocused = true
            try? await Task.sleep(for: .milliseconds(50))
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func update(_ action: String, coalesce: Bool = false, _ body: @escaping (inout TextStyle) -> Void) {
        editor.adjustClip(clip.id, actionName: action, coalesce: coalesce) { clip in
            guard var style = clip.text else { return }
            body(&style)
            clip.text = style
        }
    }

    private func textSlider(
        _ title: String, _ keyPath: WritableKeyPath<TextStyle, Double>, range: ClosedRange<Double>,
        unit: String, fractionDigits: Int = 0, unitsPerPoint: Double, action: String
    ) -> some View {
        let set: (Double) -> Void = { value in update(action) { $0[keyPath: keyPath] = value } }
        return InspectorSlider(
            title: title, value: text[keyPath: keyPath], range: range, unit: unit,
            fractionDigits: fractionDigits, unitsPerPoint: unitsPerPoint,
            onBegin: editor.beginAdjustment, onChange: set,
            onEnd: { editor.endAdjustment(action) }, onSet: set
        )
    }

    private func clipSlider(
        _ title: String, _ keyPath: WritableKeyPath<Clip, Double>, range: ClosedRange<Double>,
        displayScale: Double, unit: String, action: String
    ) -> some View {
        let id = clip.id
        let set: (Double) -> Void = { value in editor.adjustClip(id, actionName: action) { $0[keyPath: keyPath] = value } }
        return InspectorSlider(
            title: title, value: clip[keyPath: keyPath], range: range, displayScale: displayScale, unit: unit,
            onBegin: editor.beginAdjustment, onChange: set, onEnd: { editor.endAdjustment(action) }, onSet: set
        )
    }

    private func positionRow(
        _ title: String, start: WritableKeyPath<Clip, Double>, end: WritableKeyPath<Clip, Double?>, limit: Double
    ) -> some View {
        let id = clip.id
        let action = "Move Text"
        return AnimatedValueRow(
            title: title,
            start: clip[keyPath: start],
            end: clip[keyPath: end],
            range: -limit...limit,
            onBegin: editor.beginAdjustment,
            onEnd: { editor.endAdjustment(action) },
            onChangeStart: { value in editor.adjustClip(id, actionName: action) { $0[keyPath: start] = value } },
            onChangeEnd: { value in editor.adjustClip(id, actionName: action) { $0[keyPath: end] = value } },
            onSetStart: { value in editor.adjustClip(id, actionName: action) { $0[keyPath: start] = value } },
            onSetEnd: { value in
                editor.adjustClip(id, actionName: value == nil ? "Lock End Position" : action) { $0[keyPath: end] = value }
            }
        )
    }
}

/// Label plus system color well (with opacity).
private struct ColorRow: View {
    let title: String
    let color: RGBAColor
    let onChange: (RGBAColor) -> Void

    var body: some View {
        HStack(spacing: 8) {
            InspectorLabel(title)
            ColorPicker(title, selection: Binding(
                get: { Color(rgba: color) },
                set: { onChange(RGBAColor($0)) }
            ), supportsOpacity: true)
            .labelsHidden()
            Spacer()
        }
    }
}

extension Color {
    /// A user-chosen color stored in the project (not a UI theme color).
    init(rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension RGBAColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }
}
