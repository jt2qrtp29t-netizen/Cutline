import SwiftUI

/// A titled group of inspector rows with an optional reset button.
struct InspectorSection<Content: View>: View {
    let title: String
    var onReset: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title)
                Spacer()
                if let onReset {
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset \(title)")
                }
            }
            content
        }
        .padding(12)
        .background(Theme.raised.opacity(0.5), in: .rect(cornerRadius: Theme.Metrics.panelCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metrics.panelCornerRadius).strokeBorder(Theme.border)
        }
    }
}

/// Modifier-based precision used by sliders, steppers and buttons:
/// ⌥ is 10× finer, ⇧ is 10× coarser.
enum Precision {
    static var factor: Double {
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) { return 0.1 }
        if flags.contains(.shift) { return 10 }
        return 1
    }

    static let hint = "Drag to adjust. Hold ⌥ for fine control, ⇧ for coarse. ↑/↓ in the field step the value."
}

/// A slider that changes its value by a fixed amount per point dragged, independent
/// of its width, so small changes are easy. Clicking away from the knob jumps there;
/// dragging the knob moves relative to where it was grabbed.
struct PrecisionSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    /// Value change per point of horizontal drag (before modifiers).
    let unitsPerPoint: Double
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    @State private var dragValue: Double?
    @State private var lastX: CGFloat = 0
    @State private var isHovering = false

    private func fraction(_ v: Double) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return ((v - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let shown = dragValue ?? value
            let knobX = CGFloat(fraction(shown)) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.recessed).frame(height: 4)
                Capsule().fill(dragValue != nil ? Theme.accent : Theme.accent.opacity(0.7))
                    .frame(width: max(knobX, 0), height: 4)
                Circle()
                    .fill(Theme.textPrimary)
                    .overlay(Circle().strokeBorder(Theme.border))
                    .frame(width: 12, height: 12)
                    .scaleEffect(dragValue != nil || isHovering ? 1.15 : 1)
                    .offset(x: knobX - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        var current: Double
                        if let dragValue {
                            current = dragValue
                        } else {
                            onBegin()
                            current = value
                            lastX = drag.startLocation.x
                            if abs(drag.startLocation.x - knobX) > 8, width > 0 {
                                let f = Double(drag.startLocation.x / width).clamped(to: 0...1)
                                current = range.lowerBound + f * (range.upperBound - range.lowerBound)
                            }
                        }
                        // Accumulate per-event deltas so modifiers can change mid-drag.
                        let dx = Double(drag.location.x - lastX)
                        lastX = drag.location.x
                        current = (current + dx * unitsPerPoint * Precision.factor).clamped(to: range)
                        dragValue = current
                        onChange(current)
                    }
                    .onEnded { _ in
                        dragValue = nil
                        onEnd()
                    }
            )
        }
        .frame(height: 16)
        .help(Precision.hint)
    }
}

/// Numeric entry field: type a value and press Return, or step with ↑/↓
/// (⌥ finer, ⇧ coarser). Every change is a single undoable edit.
struct NumberField: View {
    let value: Double
    let range: ClosedRange<Double>
    var displayScale: Double = 1
    var unit: String = ""
    var fractionDigits = 0
    /// Arrow-key step before modifiers, in model units.
    let step: Double
    let onSet: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 1) {
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onKeyPress(.upArrow) { stepBy(+1); return .handled }
                .onKeyPress(.downArrow) { stepBy(-1); return .handled }
            if !unit.isEmpty {
                Text(unit).foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .themedField()
        .onAppear { text = formatted(value) }
        .onChange(of: value) { _, newValue in
            if !focused { text = formatted(newValue) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.\(fractionDigits)f", value * displayScale)
    }

    private func stepBy(_ direction: Double) {
        let newValue = (value + direction * step * Precision.factor).clamped(to: range)
        onSet(newValue)
        text = formatted(newValue)
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: unit, with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let typed = Double(cleaned) else {
            text = formatted(value)
            return
        }
        let newValue = (typed / displayScale).clamped(to: range)
        if newValue != value { onSet(newValue) }
        text = formatted(newValue)
    }
}

/// Precision slider plus numeric field. Dragging is one undo step; typing a value
/// and pressing Return, or stepping with ↑/↓, is one step each.
struct InspectorSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    /// Display multiplier, e.g. 100 to show 0...1 as 0...100%.
    var displayScale: Double = 1
    var unit: String = ""
    var fractionDigits = 0
    /// Value change per point dragged; defaults to the full range over 250 points.
    var unitsPerPoint: Double?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    /// Commits a typed value as a single edit.
    let onSet: (Double) -> Void

    private var perPoint: Double {
        unitsPerPoint ?? (range.upperBound - range.lowerBound) / 250
    }

    var body: some View {
        HStack(spacing: 8) {
            InspectorLabel(title)
            PrecisionSlider(value: value, range: range, unitsPerPoint: perPoint,
                            onBegin: onBegin, onChange: onChange, onEnd: onEnd)
            NumberField(value: value, range: range, displayScale: displayScale, unit: unit,
                        fractionDigits: fractionDigits, step: perPoint * 10, onSet: onSet)
                .frame(width: 70)
        }
    }
}

struct InspectorLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 68, alignment: .leading)
            .lineLimit(1)
    }
}

/// A position axis with a start value and an optional end value. While the end is
/// locked the clip stays put; unlocking it makes the clip move linearly from the
/// start position (first frame) to the end position (last frame).
struct AnimatedValueRow: View {
    let title: String
    let start: Double
    /// Nil while locked.
    let end: Double?
    let range: ClosedRange<Double>
    var unit = "px"
    var fractionDigits = 1
    var unitsPerPoint: Double = 1
    let onBegin: () -> Void
    let onEnd: () -> Void
    /// Live change during a drag (inside a begin/end pair).
    let onChangeStart: (Double) -> Void
    let onChangeEnd: (Double) -> Void
    /// Single undoable edits.
    let onSetStart: (Double) -> Void
    let onSetEnd: (Double?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                InspectorLabel(title)
                NumberField(value: start, range: range, unit: unit, fractionDigits: fractionDigits,
                            step: unitsPerPoint * 10, onSet: onSetStart)
                Button {
                    // Unlocking starts the end where the clip currently is.
                    onSetEnd(end == nil ? start : nil)
                } label: {
                    Image(systemName: end == nil ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(end == nil ? Theme.textTertiary : Theme.accent)
                        .frame(width: 18, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(end == nil ? "Unlock the end position to move the clip over its duration"
                                 : "Lock the end position (no movement)")
                NumberField(value: end ?? start, range: range, unit: unit, fractionDigits: fractionDigits,
                            step: unitsPerPoint * 10, onSet: { onSetEnd($0) })
                    .disabled(end == nil)
                    .opacity(end == nil ? 0.45 : 1)
                    .help("End position at the clip's last frame")
            }
            HStack(spacing: 8) {
                InspectorLabel(end == nil ? "" : "Start")
                PrecisionSlider(value: start, range: range, unitsPerPoint: unitsPerPoint,
                                onBegin: onBegin, onChange: onChangeStart, onEnd: onEnd)
            }
            if let end {
                HStack(spacing: 8) {
                    InspectorLabel("End")
                    PrecisionSlider(value: end, range: range, unitsPerPoint: unitsPerPoint,
                                    onBegin: onBegin, onChange: onChangeEnd, onEnd: onEnd)
                }
            }
        }
    }
}

/// Read-only label/value row.
struct InspectorValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            Spacer()
        }
        .font(.system(size: 11))
    }
}
