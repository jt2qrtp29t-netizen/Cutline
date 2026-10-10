import SwiftUI

/// RGB curves: master plus red, green and blue.
struct RGBCurvesSection: View {
    let editor: EditorController
    let clip: Clip

    @AppStorage("color.curveChannel") private var channelName = CurveChannel.master.rawValue
    private var channel: CurveChannel { CurveChannel(rawValue: channelName) ?? .master }

    var body: some View {
        let curves = clip.color.curves
        let current = curves[keyPath: channel.keyPath]
        InspectorSection(title: "Curves", onReset: { editor.resetGrade(.curves, of: clip.id) }) {
            HStack {
                Picker("Channel", selection: $channelName) {
                    ForEach(CurveChannel.allCases) { Text($0.shortTitle).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
                Spacer()
                Button("Reset \(channel.title)") { editor.setCurve(channel, to: .identity, of: clip.id, actionName: "Reset \(channel.title) Curve") }
                    .controlSize(.small)
                    .disabled(current.isIdentity && current.points.count == 2)
            }
            CurvePlot(
                points: current.points,
                curve: { ToneCurve.Evaluator(current)($0) },
                color: color(for: channel),
                ghosts: CurveChannel.allCases.filter { $0 != channel && !curves[keyPath: $0.keyPath].isIdentity }.map { other in
                    let evaluator = ToneCurve.Evaluator(curves[keyPath: other.keyPath])
                    return (curve: { evaluator($0) }, color: color(for: other))
                },
                background: {
                    ZStack {
                        Theme.curvePlot
                        // The unchanged diagonal, for reference.
                        GeometryReader { g in
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: g.size.height))
                                p.addLine(to: CGPoint(x: g.size.width, y: 0))
                            }
                            .stroke(Theme.toneCurveGrid, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                    }
                },
                onBegin: { editor.beginAdjustment() },
                onChange: { editor.setCurve(channel, to: ToneCurve(points: $0), of: clip.id) },
                onEnd: { editor.endAdjustment($0) },
                onCommit: { editor.setCurve(channel, to: ToneCurve(points: $0), of: clip.id, actionName: $1) }
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)
            Text("Click to add a point, drag to move it, double-click to remove it.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func color(for channel: CurveChannel) -> Color {
        switch channel {
        case .master: Theme.curveMaster
        case .red: Theme.curveRed
        case .green: Theme.curveGreen
        case .blue: Theme.curveBlue
        }
    }
}

/// Hue vs saturation: raise or lower the saturation of particular hues.
struct HueSaturationSection: View {
    let editor: EditorController
    let clip: Clip

    var body: some View {
        let curve = clip.color.hueSaturation
        let evaluator = HueCurve.Evaluator(curve)
        InspectorSection(title: "Hue vs Saturation", onReset: { editor.resetGrade(.hueSaturation, of: clip.id) }) {
            CurvePlot(
                points: curve.points,
                curve: { evaluator($0) / 2 },
                color: Theme.curveMaster,
                fixedEnds: false,
                background: {
                    VStack(spacing: 0) {
                        Theme.curvePlot
                        LinearGradient(stops: (0...12).map { Gradient.Stop(color: Theme.hueStrip(Double($0) / 12), location: Double($0) / 12) },
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 8)
                            .opacity(0.8)
                    }
                    .overlay {
                        GeometryReader { g in
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: g.size.height / 2))
                                p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2))
                            }
                            .stroke(Theme.toneCurveGrid, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                    }
                },
                onBegin: { editor.beginAdjustment() },
                onChange: { editor.setHueCurve(HueCurve(points: $0), of: clip.id) },
                onEnd: { editor.endAdjustment($0) },
                onCommit: { editor.setHueCurve(HueCurve(points: $0), of: clip.id, actionName: $1) }
            )
            .frame(height: 120)
            Text("Click to add a point on a hue, then drag up for more saturation or down for less. The curve wraps around at red.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A .cube LUT applied at the end of the grade.
struct LUTSection: View {
    let editor: EditorController
    let clip: Clip

    var body: some View {
        InspectorSection(title: "LUT", onReset: clip.color.lut == nil ? nil : { editor.resetGrade(.lut, of: clip.id) }) {
            if let lut = clip.color.lut {
                HStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .foregroundStyle(Theme.textSecondary)
                    Text(lut.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(lut.path)
                    Spacer()
                    Button("Replace…") { editor.chooseLUT(for: clip.id) }
                        .controlSize(.small)
                    Button("Remove") { editor.removeLUT(from: clip.id) }
                        .controlSize(.small)
                }
                if let problem = editor.lutProblem(of: clip) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.offlineBadge)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ParameterRow(editor: editor, clip: clip, property: .lutIntensity)
            } else {
                HStack {
                    Text("No LUT")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Choose .cube File…") { editor.chooseLUT(for: clip.id) }
                        .controlSize(.small)
                }
            }
        }
    }
}
