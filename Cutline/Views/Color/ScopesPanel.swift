import SwiftUI

enum ScopeKind: String, CaseIterable, Identifiable {
    case histogram, waveform, vectorscope

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Right panel of the Color tab: a video scope of the frame in the viewer, with the
/// grade applied. Updates about 15 times a second while visible.
struct ScopesPanel: View {
    let editor: EditorController

    @AppStorage("color.scope") private var kindName = ScopeKind.waveform.rawValue
    @State private var data: ScopeData?
    private var kind: ScopeKind { ScopeKind(rawValue: kindName) ?? .waveform }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Scopes")
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                Picker("Scope", selection: $kindName) {
                    ForEach(ScopeKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    if let data {
                        switch kind {
                        case .histogram: HistogramView(data: data)
                        case .waveform: WaveformView(data: data)
                        case .vectorscope: VectorscopeView(data: data)
                        }
                    } else {
                        Theme.scopeBackground
                            .overlay {
                                Text("Scopes show the frame in the viewer.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                    }
                }
                .aspectRatio(kind == .vectorscope ? 1 : 1.5, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border) }

                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .background(Theme.background)
        .task { await refreshWhileVisible() }
    }

    private var caption: String {
        switch kind {
        case .histogram: "How many pixels sit at each level, from black (left) to white (right), for red, green and blue."
        case .waveform: "Brightness across the frame: left to right as in the picture, black at the bottom, white at the top."
        case .vectorscope: "Color: hue by direction, saturation by distance from the center. The boxes mark red, yellow, green, cyan, blue and magenta; the line marks skin tones."
        }
    }

    /// Reads the displayed frame ~15 times a second and analyzes new ones off the main thread.
    private func refreshWhileVisible() async {
        let playback = editor.playback
        playback.providesFrames = true
        defer { playback.providesFrames = false }
        var analyzed = -1
        while !Task.isCancelled {
            if let frame = playback.latestFrame(), playback.frameNumber != analyzed {
                analyzed = playback.frameNumber
                let box = FrameBox(image: frame)
                let result = await Task.detached(priority: .userInitiated) { ScopeAnalyzer.analyze(box.image) }.value
                if !Task.isCancelled, let result { data = result }
            }
            try? await Task.sleep(for: .milliseconds(66))
        }
    }
}

/// Carries a frame to the analysis task (CIImage is immutable).
private struct FrameBox: @unchecked Sendable {
    let image: CIImage
}

// MARK: Histogram

struct HistogramView: View {
    let data: ScopeData

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.scopeBackground))
            drawGrid(&context, size)
            // Scale to the tallest bin, ignoring the very ends (pure black or white) so a
            // clipped frame doesn't flatten everything else.
            let peak = data.histogram[0..<3].flatMap { $0[2..<254] }.max().map(Double.init) ?? 1
            let colors = [Theme.curveRed, Theme.curveGreen, Theme.curveBlue]
            context.blendMode = .plusLighter
            for channel in 0..<3 {
                let bins = data.histogram[channel]
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (i, count) in bins.enumerated() {
                    let x = size.width * CGFloat(i) / 255
                    let h = min(1, Double(count) / max(peak, 1)) * Double(size.height) * 0.95
                    path.addLine(to: CGPoint(x: x, y: size.height - h))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(colors[channel].opacity(0.45)))
                context.stroke(path, with: .color(colors[channel].opacity(0.9)), lineWidth: 1)
            }
        }
    }

    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        var grid = Path()
        for i in 1..<4 {
            let x = size.width * CGFloat(i) / 4
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(Theme.toneCurveGrid), lineWidth: 1)
    }
}

// MARK: Waveform

struct WaveformView: View {
    let data: ScopeData

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Theme.scopeBackground
                if let image = ScopeAnalyzer.image(of: data.waveform, width: data.waveformWidth, height: ScopeData.levels,
                                                   flipRows: true) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .colorMultiply(Theme.scopeTrace)
                        .blendMode(.plusLighter)
                }
                // Graticule: 0, 25, 50, 75 and 100%.
                ForEach([0, 25, 50, 75, 100], id: \.self) { level in
                    let y = geometry.size.height * (1 - CGFloat(level) / 100)
                    Rectangle()
                        .fill(Theme.toneCurveGrid)
                        .frame(height: 1)
                        .offset(y: min(max(y - 0.5, 0), geometry.size.height - 1))
                    Text("\(level)")
                        .font(.system(size: 8, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .offset(x: 3, y: min(max(y - 11, 1), geometry.size.height - 11))
                }
            }
        }
    }
}

// MARK: Vectorscope

struct VectorscopeView: View {
    let data: ScopeData

    /// 75% color bars: where the six primaries and secondaries should land.
    private static let targets: [(name: String, rgb: (Double, Double, Double))] = [
        ("R", (0.75, 0, 0)), ("Yl", (0.75, 0.75, 0)), ("G", (0, 0.75, 0)),
        ("Cy", (0, 0.75, 0.75)), ("B", (0, 0, 0.75)), ("Mg", (0.75, 0, 0.75)),
    ]

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Theme.scopeBackground
                if let image = ScopeAnalyzer.image(of: data.vectorscope, width: ScopeData.vectorSize,
                                                   height: ScopeData.vectorSize, flipRows: false) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .colorMultiply(Theme.scopeTrace)
                        .blendMode(.plusLighter)
                }
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    for radius in [0.25, 0.5] {
                        let r = size.width * radius
                        context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                                       with: .color(Theme.toneCurveGrid), lineWidth: 1)
                    }
                    var cross = Path()
                    cross.move(to: CGPoint(x: center.x, y: 0))
                    cross.addLine(to: CGPoint(x: center.x, y: size.height))
                    cross.move(to: CGPoint(x: 0, y: center.y))
                    cross.addLine(to: CGPoint(x: size.width, y: center.y))
                    context.stroke(cross, with: .color(Theme.toneCurveGrid), lineWidth: 1)

                    // Skin tone line: from the center through a typical skin color, to the edge.
                    let skin = ScopeAnalyzer.vectorPosition(r: 0.8, g: 0.6, b: 0.5)
                    let dx = skin.x - 0.5, dy = skin.y - 0.5
                    let length = (dx * dx + dy * dy).squareRoot()
                    if length > 0 {
                        var line = Path()
                        line.move(to: center)
                        line.addLine(to: CGPoint(x: center.x + dx / length * size.width * 0.5,
                                                 y: center.y + dy / length * size.height * 0.5))
                        context.stroke(line, with: .color(Theme.textTertiary.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }

                    for target in Self.targets {
                        let p = ScopeAnalyzer.vectorPosition(r: target.rgb.0, g: target.rgb.1, b: target.rgb.2)
                        let point = CGPoint(x: p.x * size.width, y: p.y * size.height)
                        context.stroke(Path(CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
                                       with: .color(Theme.textTertiary), lineWidth: 1)
                        context.draw(Text(target.name).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.textTertiary),
                                     at: CGPoint(x: point.x + (point.x < center.x ? -12 : 12), y: point.y))
                    }
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
