import AVFoundation
import SwiftUI

/// The Animate tab: design an animation (a template, or a script) on the left, see it
/// loop in the middle, add it to the timeline below.
struct AnimateWorkspace: View {
    let editor: EditorController
    let session: AnimateSession
    @AppStorage("layout.animatePanelWidth") private var panelWidth = 400.0
    @AppStorage("animate.mode") private var mode = "templates"

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SectionLabel("Animate")
                    Spacer()
                    Picker("Mode", selection: $mode) {
                        Text("Templates").tag("templates")
                        Text("Script").tag("script")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                Rectangle().fill(Theme.border).frame(height: 1)
                if mode == "templates" {
                    ScrollView { TemplateForm(session: session).padding(12) }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.textTertiary)
                        Text("Write your own Manim scenes here: coming in the next stage.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: panelWidth)
            .background(Theme.background)
            PanelDivider(axis: .vertical, size: $panelWidth, range: 340...560)
            AnimationPreview(editor: editor, session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The template gallery and its settings.
struct TemplateForm: View {
    @Bindable var session: AnimateSession

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, unit: String = "", digits: Int = 1) -> some View {
        InspectorSlider(title: title, value: value.wrappedValue, range: range, unit: unit, fractionDigits: digits,
                        onBegin: {}, onChange: { value.wrappedValue = $0 }, onEnd: {}, onSet: { value.wrappedValue = $0 })
    }

    /// A label and a menu, lined up with the sliders.
    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            InspectorLabel(title)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5))
    }

    var body: some View {
        let s = $session.settings
        let template = session.settings.template
        let labels = template.labels
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                ForEach(AnimationTemplate.allCases) { option in
                    Button { session.choose(option) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: option.symbolName).font(.system(size: 16))
                            Text(option.title).font(.system(size: 10.5)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(option == template ? Theme.accent : Theme.textSecondary)
                        .background(option == template ? Theme.accentMuted : Theme.raised.opacity(0.5), in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Start from the \(option.title) template (replaces the settings below)")
                }
            }

            InspectorSection(title: "Text") {
                TextField(labels.text, text: s.text, axis: .vertical).themedField().font(.system(size: 12))
                if let second = labels.secondary { TextField(second, text: s.secondary).themedField().font(.system(size: 12)) }
                if let extra = labels.extra { TextField(extra, text: s.extra).themedField().font(.system(size: 12)) }
                if template == .equation {
                    Text("LaTeX, e.g. \\frac{a}{b} or x^2. Needs LaTeX installed (it is on this Mac if equations render).")
                        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                if template == .counter {
                    slider("From", s.countFrom, -1_000...1_000, digits: 0)
                    slider("To", s.countTo, -1_000...100_000, digits: 0)
                    Stepper("Decimals: \(session.settings.decimals)", value: s.decimals, in: 0...3).font(.system(size: 11.5))
                }
                if template == .countdown {
                    Stepper("Count down from \(session.settings.countdownFrom)", value: s.countdownFrom, in: 1...10).font(.system(size: 11.5))
                }
            }

            InspectorSection(title: "Look") {
                if template != .equation {
                    FontPicker(postScriptName: session.settings.fontName) { session.settings.fontName = $0 }
                    Toggle("Italic", isOn: s.italic).toggleStyle(.checkbox).font(.system(size: 11.5))
                }
                slider("Size", s.size, AnimationSettings.sizeRange, unit: " px", digits: 0)
                ColorRow(title: "Color", color: session.settings.color) { session.settings.color = $0 }
                if template != .equation {
                    Toggle("Gradient", isOn: Binding(get: { session.settings.gradient != nil },
                                                     set: { session.settings.gradient = $0 ? RGBAColor(red: 1, green: 0.82, blue: 0.2, alpha: 1) : nil }))
                        .toggleStyle(.checkbox).font(.system(size: 11.5))
                    if let gradient = session.settings.gradient {
                        ColorRow(title: "To", color: gradient) { session.settings.gradient = $0 }
                    }
                }
                slider("Outline", s.outlineWidth, 0...20, unit: " px", digits: 0)
                if session.settings.outlineWidth > 0 {
                    ColorRow(title: "Outline color", color: session.settings.outlineColor) { session.settings.outlineColor = $0 }
                }
                Toggle("Panel behind", isOn: s.panel).toggleStyle(.checkbox).font(.system(size: 11.5))
                if session.settings.panel {
                    ColorRow(title: "Panel color", color: session.settings.panelColor) { session.settings.panelColor = $0 }
                    slider("Opacity", Binding(get: { session.settings.panelOpacity * 100 }, set: { session.settings.panelOpacity = $0 / 100 }),
                           0...100, unit: "%", digits: 0)
                }
            }

            InspectorSection(title: "Position") {
                slider("Across", Binding(get: { session.settings.x * 100 }, set: { session.settings.x = $0 / 100 }), 0...100, unit: "%", digits: 0)
                slider("Down", Binding(get: { session.settings.y * 100 }, set: { session.settings.y = $0 / 100 }), 0...100, unit: "%", digits: 0)
            }

            InspectorSection(title: "Animation") {
                row("In") { Picker("In", selection: s.animationIn) { ForEach(AnimationIn.allCases) { Text($0.title).tag($0) } } }
                row("On screen") { Picker("On screen", selection: s.during) { ForEach(AnimationDuring.allCases) { Text($0.title).tag($0) } } }
                row("Out") { Picker("Out", selection: s.animationOut) { ForEach(AnimationOut.allCases) { Text($0.title).tag($0) } } }
                slider("In time", s.inTime, AnimationSettings.timeRange, unit: " s")
                slider("Hold", s.hold, 0...30, unit: " s")
                if session.settings.animationOut != .none { slider("Out time", s.outTime, AnimationSettings.timeRange, unit: " s") }
                slider("Stagger", Binding(get: { session.settings.letterDelay * 100 }, set: { session.settings.letterDelay = $0 / 100 }),
                       0...100, unit: "%", digits: 0)
                Text(String(format: "Lasts %.1f s.", session.settings.duration))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// The animation looping over a checkerboard (so its transparency shows), its state, and
/// Add to Timeline.
struct AnimationPreview: View {
    let editor: EditorController
    let session: AnimateSession

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Checkerboard()
                if let url = session.previewURL {
                    LoopingPlayer(url: url)
                }
                status
            }
            .aspectRatio(CGFloat(editor.state.settings.width) / CGFloat(max(editor.state.settings.height, 1)), contentMode: .fit)
            .clipShape(.rect(cornerRadius: 6))
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 10) {
                if let installation = session.installation {
                    Text("Manim \(installation.version)")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button {
                    session.addToTimeline(editor)
                } label: {
                    if session.isAdding { ProgressView().controlSize(.small) } else { Label("Add to Timeline", systemImage: "plus.rectangle.on.rectangle") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.installation == nil || session.isAdding)
                .help("Renders it at the project's size and frame rate and places it at the playhead, above your footage")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .checking:
            ProgressView().controlSize(.small)
        case .notInstalled:
            VStack(spacing: 10) {
                Image(systemName: "wand.and.stars").font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
                Text("Animate uses Manim, installed on your Mac (it isn't part of Cutline).")
                    .font(.system(size: 12, weight: .medium))
                Text("In Terminal:  brew install cairo pango  then  pip3 install manim\nLaTeX (for equations) is optional.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                Button("Check Again") { session.recheck() }.controlSize(.small)
            }
            .padding(20)
            .background(Theme.background.opacity(0.92), in: .rect(cornerRadius: 10))
        case .rendering(let fraction):
            VStack { Spacer(); ProgressView(value: fraction).frame(width: 180).padding(10) }
        case .failed(let message):
            VStack {
                Spacer()
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.sandbox)
                    .padding(10)
                    .background(Theme.background.opacity(0.92), in: .rect(cornerRadius: 8))
                    .padding(10)
            }
        case .idle:
            EmptyView()
        }
    }
}

/// Gray squares behind transparent content.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.checkerLight))
            for y in stride(from: 0, to: size.height, by: cell) {
                for x in stride(from: 0, to: size.width, by: cell) where (Int(x / cell) + Int(y / cell)) % 2 == 0 {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Theme.checkerDark))
                }
            }
        }
    }
}

/// A movie playing on a loop, muted.
struct LoopingPlayer: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var looper: AVPlayerLooper?
        var url: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LoopingPlayerView {
        let view = LoopingPlayerView()
        load(view, context: context)
        return view
    }

    func updateNSView(_ view: LoopingPlayerView, context: Context) {
        if context.coordinator.url != url { load(view, context: context) }
    }

    private func load(_ view: LoopingPlayerView, context: Context) {
        let player = AVQueuePlayer()
        player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        context.coordinator.url = url
        view.playerLayer.player = player
        player.play()
    }
}

final class LoopingPlayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
