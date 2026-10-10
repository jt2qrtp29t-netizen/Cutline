import SwiftUI

/// One primary color wheel: drag the puck to tint (⌥ for fine control), use the
/// slider for the master amount, double-click the wheel to reset it. The diamond
/// keyframes the whole wheel at the playhead.
struct ColorWheelControl: View {
    let editor: EditorController
    let clip: Clip
    let wheel: GradeWheel

    @State private var dragStart: ColorWheel?

    var body: some View {
        let values = editor.wheel(wheel, of: clip)
        let keyed = editor.wheelHasKeyframeHere(wheel, in: clip)
        let animated = wheel.allProperties.contains { clip.isAnimated($0) }

        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(wheel.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(animated ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                Button {
                    editor.toggleWheelKeyframe(wheel, in: clip)
                } label: {
                    KeyframeDiamond(isFilled: keyed, size: 10)
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(editor.playheadOffset(in: clip) == nil)
                .help(keyed ? "Remove \(wheel.title) keyframe at playhead" : "Add \(wheel.title) keyframe at playhead")
            }

            GeometryReader { geometry in
                let diameter = min(geometry.size.width, geometry.size.height)
                let radius = diameter / 2
                ZStack {
                    WheelDisc()
                    // Crosshair.
                    Path { path in
                        path.move(to: CGPoint(x: radius, y: radius * 0.2))
                        path.addLine(to: CGPoint(x: radius, y: radius * 1.8))
                        path.move(to: CGPoint(x: radius * 0.2, y: radius))
                        path.addLine(to: CGPoint(x: radius * 1.8, y: radius))
                    }
                    .stroke(Theme.wheelRing.opacity(0.35), lineWidth: 1)
                    Circle()
                        .strokeBorder(Theme.wheelPuck, lineWidth: 2)
                        .background(Circle().fill(Theme.wheelHue(x: values.x, y: values.y)))
                        .frame(width: 12, height: 12)
                        .shadow(color: Theme.shadow, radius: 2)
                        .position(x: radius + values.x * radius, y: radius - values.y * radius)
                }
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .gesture(dragGesture(radius: radius))
                .simultaneousGesture(TapGesture(count: 2).onEnded { editor.resetWheel(wheel, of: clip.id) })
                .frame(maxWidth: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)
            .help("\(wheel.help) Drag to tint (⌥ for fine control); double-click to reset.")

            HStack(spacing: 6) {
                PrecisionSlider(
                    value: values.master, range: -1...1, unitsPerPoint: 0.004,
                    onBegin: { editor.beginAdjustment() },
                    onChange: { editor.setGradeValues([wheel.properties.master: $0], of: clip.id, actionName: "Change \(wheel.title)") },
                    onEnd: { editor.endAdjustment("Change \(wheel.title)") }
                )
                NumberField(value: values.master, range: -1...1, displayScale: 100, unit: "", fractionDigits: 0, step: 0.01) {
                    editor.setGradeValues([wheel.properties.master: $0], of: clip.id, actionName: "Change \(wheel.title)")
                }
                .frame(width: 46)
            }
        }
    }

    private func dragGesture(radius: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = editor.wheel(wheel, of: clip)
                    editor.beginAdjustment()
                }
                guard let start = dragStart, radius > 0 else { return }
                // Relative to where the puck was, so grabbing anywhere doesn't jump it; ⌥ is 10× finer.
                let factor = Precision.factor >= 1 ? 1 : Precision.factor
                var x = start.x + Double(value.translation.width / radius) * factor
                var y = start.y - Double(value.translation.height / radius) * factor
                let length = (x * x + y * y).squareRoot()
                if length > 1 {
                    x /= length
                    y /= length
                }
                editor.setGradeValues([wheel.properties.x: x, wheel.properties.y: y], of: clip.id,
                                      actionName: "Change \(wheel.title)")
            }
            .onEnded { _ in
                dragStart = nil
                editor.endAdjustment("Change \(wheel.title)")
            }
    }
}

/// The hue disc: hues around the edge (as on a vectorscope), gray in the middle.
private struct WheelDisc: View {
    private static let stops: [Gradient.Stop] = (0...36).map { i in
        // SwiftUI's angular gradient runs clockwise from 3 o'clock with y down; the wheel's
        // y axis points up, so the angle is mirrored.
        let angle = Double(i) / 36 * 2 * .pi
        return Gradient.Stop(color: Theme.wheelHue(x: cos(angle), y: -sin(angle)), location: Double(i) / 36)
    }

    var body: some View {
        Circle()
            .fill(AngularGradient(stops: Self.stops, center: .center))
            .overlay {
                Circle().fill(RadialGradient(colors: [Theme.wheelCenter, Theme.wheelCenter.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: 80))
            }
            .overlay { Circle().strokeBorder(Theme.wheelRing, lineWidth: 2) }
    }
}
