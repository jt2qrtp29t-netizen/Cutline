import SwiftUI

/// Right panel of the Effects tab: the selected parameter's value over the clip's
/// duration. Keyframes can be dragged in time and value; the blue handles shape the
/// easing of each segment (a custom Bézier curve).
struct CurveEditorPanel: View {
    let editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionLabel("Curve")
                Menu {
                    ForEach(AnimatableProperty.allCases) { property in
                        Button(property.title) { editor.effectsProperty = property }
                    }
                } label: {
                    Text(editor.effectsProperty.title)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            if let clip = editor.effectsClip {
                CurveGraph(editor: editor, clip: clip, property: editor.effectsProperty)
                    .padding(10)
                easingBar(for: clip)
            } else {
                Text("Select a video or text clip to see its curves.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
    }

    /// Quick easing buttons for the selected keyframe of the shown parameter.
    @ViewBuilder
    private func easingBar(for clip: Clip) -> some View {
        let ref = editor.selectedKeyframes.first { $0.clipID == clip.id && $0.property == editor.effectsProperty }
        let current = ref.flatMap { editor.keyframe($0) }?.easing
        HStack(spacing: 4) {
            ForEach(Easing.presets, id: \.self) { easing in
                Button(easing.title) {
                    if let ref { editor.setEasing(easing, for: ref) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(current?.isSameKind(as: easing) == true ? Theme.textOnAccent : Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(current?.isSameKind(as: easing) == true ? Theme.accent : Theme.raised, in: .rect(cornerRadius: 4))
            }
            Spacer()
        }
        .disabled(ref == nil)
        .opacity(ref == nil ? 0.5 : 1)
        .help(ref == nil ? "Select a keyframe to change its easing" : "Easing from the selected keyframe to the next")
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

private struct CurveGraph: View {
    let editor: EditorController
    let clip: Clip
    let property: AnimatableProperty

    /// The value range is frozen while dragging so the graph doesn't rescale under the pointer.
    @State private var frozenRange: ClosedRange<Double>?

    private var frames: [Keyframe] { clip.animation.keyframes(for: property) }

    private var valueRange: ClosedRange<Double> {
        if let frozenRange { return frozenRange }
        let samples = (0...120).map { i in
            clip.value(of: property, at: clip.start + clip.duration.scaled(by: Double(i) / 120))
        } + frames.map(\.value)
        let low = samples.min() ?? 0, high = samples.max() ?? 1
        let minimumSpan: Double = switch property {
        case .positionX, .positionY: 100
        case .scale, .opacity: 0.2
        case .rotation, .yaw, .pitch: 20
        }
        let span = max(high - low, minimumSpan)
        let mid = (low + high) / 2
        return (mid - span * 0.65)...(mid + span * 0.65)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let range = valueRange
            let duration = max(clip.duration.seconds, 1e-6)
            let map = CurveMapping(size: size, duration: duration, range: range)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawGrid(context, size: size, map: map)
                    // The curve itself, sampled from the shared evaluation function.
                    var curve = Path()
                    for i in 0...240 {
                        let t = duration * Double(i) / 240
                        let point = map.point(time: t, value: clip.value(of: property, at: clip.start + Time(seconds: t)))
                        i == 0 ? curve.move(to: point) : curve.addLine(to: point)
                    }
                    context.stroke(curve, with: .color(Theme.curve), lineWidth: 2)
                    // Handle arms.
                    for (a, b) in zip(frames, frames.dropFirst()) {
                        let (h1, h2) = handles(a, b)
                        var arms = Path()
                        arms.move(to: map.point(time: a.time.seconds, value: a.value))
                        arms.addLine(to: map.point(time: h1.time, value: h1.value))
                        arms.move(to: map.point(time: b.time.seconds, value: b.value))
                        arms.addLine(to: map.point(time: h2.time, value: h2.value))
                        context.stroke(arms, with: .color(Theme.curveHandle.opacity(0.6)), lineWidth: 1)
                    }
                    // Playhead.
                    if let offset = editor.playheadOffset(in: clip) {
                        let x = map.x(offset.seconds)
                        context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(Theme.playhead))
                    }
                }
                .contentShape(.rect)
                .onTapGesture { editor.selectedKeyframes = [] }

                ForEach(Array(zip(frames, frames.dropFirst()).enumerated()), id: \.offset) { _, pair in
                    let (a, b) = pair
                    let (h1, h2) = handles(a, b)
                    handle(at: map.point(time: h1.time, value: h1.value), segment: (a, b), first: true, map: map)
                    handle(at: map.point(time: h2.time, value: h2.value), segment: (a, b), first: false, map: map)
                }

                ForEach(frames) { frame in
                    let ref = KeyframeRef(clipID: clip.id, property: property, keyframeID: frame.id)
                    KeyframeDiamond(isFilled: true, isSelected: editor.selectedKeyframes.contains(ref), size: 12)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                        .position(map.point(time: frame.time.seconds, value: frame.value))
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("curve"))
                                .onChanged { drag in
                                    if frozenRange == nil { frozenRange = range }
                                    editor.selectedKeyframes = [ref]
                                    let (time, value) = map.timeValue(at: drag.location)
                                    editor.dragKeyframe(ref, toTime: Time(seconds: time), value: value)
                                }
                                .onEnded { _ in
                                    frozenRange = nil
                                    editor.endGesture("Move Keyframe")
                                }
                        )
                        .onTapGesture { editor.selectedKeyframes = [ref] }
                        .help("\(property.formatted(frame.value)) at \(Timecode.string(for: clip.start + frame.time, fps: editor.fps))")
                }

                if frames.isEmpty {
                    // Inside the plot, below the flat line, on a backing so nothing shows through.
                    Text("\(property.title) isn't animated. Click ◆ in the Effects panel to add keyframes.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.recessed.opacity(0.9), in: .rect(cornerRadius: 5))
                        .padding(.leading, CurveMapping.labelGutter + 8)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named("curve"))
            .background(Theme.recessed, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            .clipShape(.rect(cornerRadius: 6))
        }
    }

    /// Control points of the segment a → b as (time, value) positions.
    private func handles(_ a: Keyframe, _ b: Keyframe) -> (h1: (time: Double, value: Double), h2: (time: Double, value: Double)) {
        let c = a.easing.controlPoints ?? (1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3)
        let dt = (b.time - a.time).seconds, dv = b.value - a.value
        return ((a.time.seconds + c.x1 * dt, a.value + c.y1 * dv), (a.time.seconds + c.x2 * dt, a.value + c.y2 * dv))
    }

    private func handle(at point: CGPoint, segment: (Keyframe, Keyframe), first: Bool, map: CurveMapping) -> some View {
        let (a, b) = segment
        let ref = KeyframeRef(clipID: clip.id, property: property, keyframeID: a.id)
        return Circle()
            .fill(Theme.curveHandle)
            .overlay(Circle().stroke(Theme.recessed, lineWidth: 1))
            .frame(width: 8, height: 8)
            .frame(width: 18, height: 18)
            .contentShape(.rect)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("curve"))
                    .onChanged { drag in
                        if frozenRange == nil { frozenRange = valueRange }
                        editor.selectedKeyframes = [ref]
                        let (time, value) = map.timeValue(at: drag.location)
                        let dt = (b.time - a.time).seconds, dv = b.value - a.value
                        let c = a.easing.controlPoints ?? (1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3)
                        let x = dt > 0 ? ((time - a.time.seconds) / dt).clamped(to: 0...1) : (first ? c.x1 : c.x2)
                        // A segment between equal values has no height to shape; keep its y.
                        let y = abs(dv) > 1e-9 ? (value - a.value) / dv : (first ? c.y1 : c.y2)
                        let easing: Easing = first
                            ? .bezier(x1: x, y1: y, x2: c.x2, y2: c.y2)
                            : .bezier(x1: c.x1, y1: c.y1, x2: x, y2: y)
                        editor.setEasing(easing, for: ref, live: true)
                    }
                    .onEnded { _ in
                        frozenRange = nil
                        editor.endGesture("Change Easing")
                    }
            )
            .help("Drag to shape the easing")
    }

    private func drawGrid(_ context: GraphicsContext, size: CGSize, map: CurveMapping) {
        // Label column on the left, separated from the plot.
        let gutter = CurveMapping.labelGutter
        context.fill(Path(CGRect(x: 0, y: 0, width: gutter, height: size.height)), with: .color(Theme.background))
        context.fill(Path(CGRect(x: gutter, y: 0, width: 1, height: size.height)), with: .color(Theme.border))

        var grid = Path()
        for i in 0...4 {
            // Grid lines sit on the same values as the labels.
            let value = map.range.upperBound - (map.range.upperBound - map.range.lowerBound) * Double(i) / 4
            let y = map.y(value)
            grid.addRect(CGRect(x: gutter, y: y.rounded(), width: size.width - gutter, height: 1))
            context.draw(
                Text(property.formatted(value)).font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: gutter - 6, y: y), anchor: .trailing
            )
        }
        context.fill(grid, with: .color(Theme.curveGrid))
    }
}

/// Converts between curve-editor points and (time in seconds, value).
/// The left gutter is reserved for the value labels, so the curve never runs under them.
private struct CurveMapping {
    let size: CGSize
    let duration: Double
    let range: ClosedRange<Double>
    static let labelGutter: CGFloat = 64
    let inset: CGFloat = 12

    private var left: CGFloat { Self.labelGutter + inset }
    private var plotWidth: CGFloat { max(size.width - left - inset, 1) }
    private var plotHeight: CGFloat { max(size.height - inset * 2, 1) }

    func x(_ time: Double) -> CGFloat {
        left + CGFloat(time / duration) * plotWidth
    }

    func y(_ value: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        return inset + CGFloat((range.upperBound - value) / span) * plotHeight
    }

    func point(time: Double, value: Double) -> CGPoint { CGPoint(x: x(time), y: y(value)) }

    func timeValue(at point: CGPoint) -> (Double, Double) {
        let time = Double((point.x - left) / plotWidth) * duration
        let span = range.upperBound - range.lowerBound
        let value = range.upperBound - Double((point.y - inset) / plotHeight) * span
        return (time.clamped(to: 0...duration), value)
    }
}
