import SwiftUI

/// A clip on the timeline: a rounded block with a label strip, showing a
/// thumbnail filmstrip (video tracks, blue) or a waveform (audio tracks, teal).
struct ClipView: View {
    let editor: EditorController
    let clip: Clip
    let kind: TrackKind
    let isLocked: Bool
    let media: MediaItem?
    let layout: TimelineLayout
    let isSelected: Bool
    /// Visible horizontal range in the clip's own coordinates.
    let visibleRange: ClosedRange<CGFloat>

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metrics.clipCornerRadius)
    }

    @State private var isHovering = false

    private var isAudio: Bool { kind == .audio }

    /// How loud the clip plays over time (gain, volume, fades, crossfades), for its waveform.
    private var audioEnvelope: ClipEnvelope {
        ClipEnvelope(clip, track: editor.state.track(ofClip: clip.id), isActive: true, monoSource: false)
    }
    private var fill: Color {
        clip.isText ? Theme.textClipFill : (isAudio ? Theme.audioClipFill : Theme.clipFill)
    }
    private var border: Color {
        if clip.isText { return isSelected ? Theme.textClipBorderSelected : Theme.textClipBorder }
        if isAudio { return isSelected ? Theme.audioClipBorderSelected : Theme.audioClipBorder }
        return isSelected ? Theme.clipBorderSelected : Theme.clipBorder
    }

    var body: some View {
        let isOffline = !clip.isText && clip.generator == nil && (media.map { !MediaURLCache.shared.isAvailable($0) } ?? true)
        VStack(spacing: 0) {
            label
            if let text = clip.text {
                TextClipPreview(text: text.string, leading: max(0, visibleRange.lowerBound))
            } else if let generator = clip.generator {
                GeneratorClipPreview(generator: generator, leading: max(0, visibleRange.lowerBound))
            } else if let media, !isOffline {
                Group {
                    if isAudio {
                        Waveform(clip: clip, envelope: audioEnvelope, media: media, layout: layout, visibleRange: visibleRange)
                    } else {
                        Filmstrip(clip: clip, media: media, layout: layout, visibleRange: visibleRange, fps: editor.fps,
                                  isDragging: editor.store.isLiveEditing)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            } else {
                Theme.clipOffline
                    .overlay {
                        Label("Media offline", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.clipText)
                            .lineLimit(1)
                            .help("“\(media?.path ?? clip.name)” is missing. Right-click to relink it.")
                    }
            }
        }
        .background(fill)
        .overlay { if isLocked || clip.isLocked { Theme.lockedClipDim } }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(border, lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(shape)
        .onTapGesture { toggleSelection() }
        .gesture(moveGesture)
        .overlay(alignment: .leading) { if !clip.isLocked { trimHandle(.leading) } }
        .overlay(alignment: .trailing) { if !clip.isLocked { trimHandle(.trailing) } }
        .overlay {
            if isAudio, !isLocked, !clip.isLocked, !isOffline {
                FadeOverlay(editor: editor, clip: clip, layout: layout, showsHandles: isSelected || isHovering)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu { ClipContextMenu(editor: editor, clip: clip, isSelected: isSelected) }
        // Clips on locked tracks can't be selected or edited; clicks fall through to the lane.
        .allowsHitTesting(!isLocked)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(TimelineCoordinateSpace.lanes))
            .onChanged { value in
                editor.dragClips(grabbing: clip.id, translationX: value.translation.width,
                                 pointerY: value.location.y, layout: layout)
            }
            .onEnded { _ in
                editor.endGesture(editor.selection.count > 1 ? "Move Clips" : "Move Clip")
            }
    }

    @ViewBuilder
    private func trimHandle(_ edge: ClipEdge) -> some View {
        // Narrow clips keep a usable body to grab between the handles.
        let width = min(Theme.Metrics.trimHandleWidth, layout.width(for: clip.duration) / 3)
        TrimHandle(edge: edge, isSelected: isSelected, kind: kind)
            .frame(width: width)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineCoordinateSpace.lanes))
                    .onChanged { value in
                        editor.trimClip(clip.id, edge: edge, translationX: value.translation.width, layout: layout)
                    }
                    .onEnded { _ in editor.endGesture("Trim Clip") }
            )
    }

    private var label: some View {
        // Keep the title visible when the clip's start is scrolled off to the left.
        let leading = max(0, visibleRange.lowerBound)
        return HStack(spacing: 4) {
            if isLocked || clip.isLocked {
                Image(systemName: "lock.fill").font(.system(size: 8))
            }
            if clip.linkID != nil {
                Image(systemName: "link").font(.system(size: 8, weight: .bold))
            }
            if clip.isMuted {
                ClipBadge(text: isAudio ? "M" : "H", tint: Theme.mutedTrack)
            }
            if clip.isSoloed {
                ClipBadge(text: "S", tint: Theme.soloTrack)
            }
            if !clip.color.isNeutral || clip.animation.keyframes.keys.contains(where: \.isColor) {
                Image(systemName: "camera.filters").font(.system(size: 8, weight: .bold))
                    .help("Color graded")
            }
            if let problem = editor.lutProblem(of: clip) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.offlineBadge)
                    .help(problem)
            }
            Text(clip.name)
                .lineLimit(1)
            if let label = clip.speedLabel {
                Text(label)
                    .padding(.horizontal, 3)
                    .background(fill, in: .rect(cornerRadius: 3))
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.clipText)
        .padding(.leading, 6 + leading)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.Metrics.clipLabelHeight)
        .background(clip.isText ? Theme.textClipLabelStrip : (isAudio ? Theme.audioClipLabelStrip : Theme.clipLabelStrip))
    }

    private func toggleSelection() {
        editor.select(clip.id, modifiers: NSEvent.modifierFlags)
    }
}

/// The text of a text clip, shown where other clips show thumbnails.
private struct TextClipPreview: View {
    let text: String
    let leading: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "textformat")
                .font(.system(size: 11, weight: .semibold))
            Text(text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.clipText)
        .padding(.leading, 8 + leading)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }
}

/// Small letter badge in a clip's label strip (muted / hidden / soloed).
private struct ClipBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(Theme.textOnAccent)
            .frame(width: 11, height: 11)
            .background(tint, in: .rect(cornerRadius: 2))
    }
}

private extension Clip {
    /// Whether the clip sits on an audio track (its menu says "Mute" rather than "Hide").
    func isAudioLabel(_ editor: EditorController) -> Bool {
        editor.state.track(ofClip: id)?.kind == .audio
    }
}

/// Right-click menu for a clip. Acts on the selection; right-clicking an
/// unselected clip selects it (and its linked clips) first.
private struct ClipContextMenu: View {
    let editor: EditorController
    let clip: Clip
    let isSelected: Bool

    static let speedPresets: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4]

    var body: some View {
        let targets = editor.contextTargets(for: clip.id)
        PlaygroundClipMenuItems(editor: editor, clip: clip, targets: targets)
        Divider()
        if !clip.isText, let media = editor.state.mediaItem(clip.mediaID), editor.isOffline(media) {
            Button("Relink “\(media.name)”…") { editor.relinkMedia(media.id) }
            Divider()
        }
        Button(editor.isLinked(targets) ? "Unlink" : "Link") { editor.toggleLink(targets) }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!editor.canToggleLink(targets))
        Button(editor.isLocked(targets) ? "Unlock Clip" : "Lock Clip") { editor.toggleLock(targets) }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        Divider()
        // Mute and solo apply to the clicked clip, or to the selection it belongs to.
        Toggle(clip.isAudioLabel(editor) ? "Mute" : "Hide", isOn: Binding(
            get: { editor.areMuted(targets) },
            set: { _ in editor.toggleMute(targets) }
        ))
        Toggle("Solo", isOn: Binding(
            get: { editor.areSoloed(targets) },
            set: { _ in editor.toggleSolo(targets) }
        ))
        if clip.isAudioLabel(editor) {
            Divider()
            AudioClipMenuItems(editor: editor, clip: clip, targets: targets)
        }
        if editor.state.track(ofClip: clip.id)?.kind.isVisual == true {
            Divider()
            Button("Copy Grade") {
                editor.selection = [clip.id]
                editor.copyGrade()
            }
            Button("Paste Grade") {
                if !isSelected { editor.selection = [clip.id] }
                editor.pasteGrade()
            }
            .disabled(editor.copiedGrade == nil)
            Button("Apply Grade to All Clips on Track") { editor.applyGradeToTrack(from: clip.id) }
            Divider()
            Menu("Animate In") {
                ForEach(AnimationPreset.inOutPresets) { preset in
                    Button(preset.title(for: .animateIn)) {
                        editor.applyPreset(preset, placement: .animateIn, duration: preset.defaultDuration, to: targets)
                    }
                }
            }
            Menu("Animate Out") {
                ForEach(AnimationPreset.inOutPresets) { preset in
                    Button(preset.title(for: .animateOut)) {
                        editor.applyPreset(preset, placement: .animateOut, duration: preset.defaultDuration, to: targets)
                    }
                }
            }
            Menu("Gameplay at Playhead") {
                ForEach(AnimationPreset.gameplayPresets) { preset in
                    Button(preset.title(for: .animateIn)) {
                        editor.applyPreset(preset, placement: .at(.zero), duration: preset.defaultDuration, to: targets)
                    }
                }
            }
        }
        Divider()
        Menu("Speed") {
            ForEach(Self.speedPresets, id: \.self) { speed in
                Button {
                    editor.setSpeed(speed, of: targets)
                } label: {
                    if !clip.hasSpeedRamp && abs(clip.speed - speed) < 0.0001 {
                        Label("\(Int(speed * 100))%", systemImage: "checkmark")
                    } else {
                        Text("\(Int(speed * 100))%")
                    }
                }
            }
            Divider()
            Button("Custom Speed…") { editor.showClipDialog(.speed, for: clip.id) }
        }
        .disabled(clip.isLocked)
        Button("Duration…") { editor.showClipDialog(.duration, for: clip.id) }
            .disabled(clip.isLocked)
        Divider()
        Button("Blade at Playhead") { editor.blade(targets) }
            .disabled(clip.isLocked)
        Button("Delete", role: .destructive) { editor.deleteClips(targets) }
            .disabled(clip.isLocked)
    }
}

/// Audio peaks drawn across the clip. Only the visible part is drawn, and the height
/// follows how loud the clip plays there: clip gain, volume (with keyframes), fades and
/// crossfades, from the same evaluator as playback.
private struct Waveform: View {
    let clip: Clip
    let envelope: ClipEnvelope
    let media: MediaItem
    let layout: TimelineLayout
    let visibleRange: ClosedRange<CGFloat>

    private var cache: WaveformCache { .shared }

    var body: some View {
        GeometryReader { geometry in
            let _ = cache.revision
            let width = geometry.size.width
            let lower = max(0, visibleRange.lowerBound)
            let upper = min(width, visibleRange.upperBound)
            if upper > lower, let peaks = cache.peaks(for: media, url: MediaURLCache.shared.url(for: media)), !peaks.isEmpty {
                let clipValue = clip
                let envelopeValue = envelope
                let pps = layout.pixelsPerSecond
                Canvas { context, size in
                    let mid = size.height / 2
                    var path = Path()
                    let step: CGFloat = 2
                    var x: CGFloat = 0
                    while x < size.width {
                        // Peak over the source span covered by this column.
                        let t0 = clipValue.sourceTime(at: clipValue.start + Time(seconds: Double(lower + x) / pps))
                        let t1 = clipValue.sourceTime(at: clipValue.start + Time(seconds: Double(lower + x + step) / pps))
                        let i0 = max(0, Int(t0.seconds * WaveformCache.bucketsPerSecond))
                        let i1 = min(peaks.count, max(i0 + 1, Int(t1.seconds * WaveformCache.bucketsPerSecond)))
                        var peak: Float = 0
                        if i0 < i1 { for i in i0..<i1 { peak = max(peak, peaks[i]) } }
                        let level = min(envelopeValue.level(at: clipValue.start + Time(seconds: Double(lower + x + step / 2) / pps)), 2)
                        let h = max(0.5, CGFloat(peak) * CGFloat(level) * mid * 0.95)
                        path.addRect(CGRect(x: x, y: mid - min(h, mid), width: step - 0.5, height: min(h, mid) * 2))
                        x += step
                    }
                    context.fill(path, with: .color(Theme.waveform))
                }
                .frame(width: upper - lower, height: geometry.size.height)
                .offset(x: lower)
            }
        }
        .clipped()
    }
}

/// Fades and crossfades in an audio clip's right-click menu.
private struct AudioClipMenuItems: View {
    let editor: EditorController
    let clip: Clip
    let targets: Set<UUID>

    static let lengths: [Double] = [0.1, 0.25, 0.5, 1, 2]

    var body: some View {
        fadeMenu("Fade In", edge: .leading, fade: clip.fadeIn)
        fadeMenu("Fade Out", edge: .trailing, fade: clip.fadeOut)
        Button("Normalize Clip to " + String(format: "%.0f LUFS", editor.state.audio.loudnessTarget).replacingOccurrences(of: "-", with: "−")) {
            editor.normalize(.clip(clip.id))
        }
        .disabled(editor.audioActivity != nil)
        Button("Crossfade with Previous Clip") { editor.addCrossfade(to: clip.id, after: false) }
            .disabled(editor.neighbor(of: clip.id, after: false) == nil)
        Button("Crossfade with Next Clip") { editor.addCrossfade(to: clip.id, after: true) }
            .disabled(editor.neighbor(of: clip.id, after: true) == nil)
    }

    private func fadeMenu(_ title: String, edge: ClipEdge, fade: AudioFade) -> some View {
        Menu(title) {
            Button("None") { editor.setFade(edge, of: targets, to: .zero) }
            ForEach(Self.lengths, id: \.self) { seconds in
                Button {
                    editor.setFade(edge, of: targets, to: Time(seconds: seconds))
                } label: {
                    if abs(fade.duration.seconds - seconds) < 0.001 {
                        Label(Self.label(seconds), systemImage: "checkmark")
                    } else {
                        Text(Self.label(seconds))
                    }
                }
            }
            Divider()
            Picker("Curve", selection: Binding(get: { fade.curve }, set: { editor.setFadeCurve(edge, of: targets, to: $0) })) {
                ForEach(FadeCurve.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
    }

    static func label(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%g s", seconds)
    }
}

/// An audio clip's fades: the curve of each fade drawn over the clip with the faded
/// part shaded, and a handle at its inner end to drag the fade longer or shorter.
private struct FadeOverlay: View {
    let editor: EditorController
    let clip: Clip
    let layout: TimelineLayout
    let showsHandles: Bool

    @State private var dragStart: Time?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let top = Theme.Metrics.clipLabelHeight
            let height = max(geometry.size.height - top, 1)
            let fadeIn = layout.width(for: clip.fadeIn.duration)
            let fadeOut = layout.width(for: clip.fadeOut.duration)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for (edge, length, curve) in [(ClipEdge.leading, fadeIn, clip.fadeIn.curve), (.trailing, fadeOut, clip.fadeOut.curve)]
                    where length > 0.5 {
                        var line = Path()
                        let steps = max(Int(length / 2), 4)
                        for i in 0...steps {
                            let u = Double(i) / Double(steps)
                            let x = edge == .leading ? length * u : width - length * u
                            let y = top + height * (1 - curve.gain(u))
                            if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        var shade = line
                        shade.addLine(to: CGPoint(x: edge == .leading ? length : width - length, y: top))
                        shade.addLine(to: CGPoint(x: edge == .leading ? 0 : width, y: top))
                        shade.closeSubpath()
                        context.fill(shade, with: .color(Theme.fadeShade))
                        context.stroke(line, with: .color(Theme.fadeLine), lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)
                if showsHandles && width > 24 {
                    handle(.leading, x: fadeIn, top: top, maxX: width)
                    handle(.trailing, x: width - fadeOut, top: top, maxX: width)
                }
            }
        }
    }

    private func handle(_ edge: ClipEdge, x: CGFloat, top: CGFloat, maxX: CGFloat) -> some View {
        let size: CGFloat = 9
        let current = edge == .leading ? clip.fadeIn.duration : clip.fadeOut.duration
        return RoundedRectangle(cornerRadius: 2)
            .fill(Theme.fadeHandle)
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.fadeLine, lineWidth: 1) }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
            .frame(width: 16, height: 16)
            .contentShape(.rect)
            .position(x: min(max(x, size / 2 + 1), maxX - size / 2 - 1), y: top + 6)
            .pointerStyle(.columnResize)
            .help(edge == .leading ? "Fade in: drag to change its length" : "Fade out: drag to change its length")
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = current }
                        guard let start = dragStart else { return }
                        let seconds = Double(value.translation.width) / layout.pixelsPerSecond * (edge == .leading ? 1 : -1)
                        editor.adjustFade(edge, of: clip.id, to: start + Time(seconds: seconds))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        editor.endAudioAdjustment(edge == .leading ? "Change Fade In" : "Change Fade Out")
                    }
            )
    }
}

/// Grab zone at a clip edge; shows a bracket when hovered or selected.
private struct TrimHandle: View {
    let edge: ClipEdge
    let isSelected: Bool
    let kind: TrackKind

    private var selectedColor: Color {
        switch kind {
        case .video: Theme.clipBorderSelected
        case .audio: Theme.audioClipBorderSelected
        case .text: Theme.textClipBorderSelected
        }
    }

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Theme.clipFill.opacity(0.001)
            if isHovering || isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isHovering ? Theme.clipText : selectedColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
                    .padding(edge == .leading ? .leading : .trailing, 2)
            }
        }
        .contentShape(.rect)
        .pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing, directions: [.inward, .outward]))
        .onHover { isHovering = $0 }
    }
}

/// Thumbnails tiled across the clip. Only tiles inside the visible range are created,
/// and source times are quantized so zooming mostly reuses cached frames.
private struct Filmstrip: View {
    let clip: Clip
    let media: MediaItem
    let layout: TimelineLayout
    let visibleRange: ClosedRange<CGFloat>
    let fps: Int
    /// Mid-drag (e.g. a speed change), tiles show the nearest frame already made and new
    /// ones are made when the drag ends, instead of queuing a decode on every step.
    let isDragging: Bool

    private var cache: ThumbnailCache { .shared }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let aspect = media.height > 0 ? CGFloat(media.width) / CGFloat(media.height) : 16 / 9
            let tileWidth = max(height * aspect, 16)
            let tiles = visibleTiles(width: geometry.size.width, tileWidth: tileWidth)
            let _ = cache.revision
            ZStack(alignment: .topLeading) {
                ForEach(tiles, id: \.self) { tile in
                    if let image = cache.image(for: tile.request, generate: !isDragging) {
                        Image(decorative: image, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: tileWidth, height: height)
                            .clipped()
                            .offset(x: tile.x)
                    }
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .topLeading)
            .clipped()
        }
    }

    private struct Tile: Hashable {
        let x: CGFloat
        let request: ThumbnailCache.Request
    }

    private func visibleTiles(width: CGFloat, tileWidth: CGFloat) -> [Tile] {
        guard width > 0 else { return [] }
        let first = max(0, Int((visibleRange.lowerBound / tileWidth).rounded(.down)))
        let last = min(Int((width / tileWidth).rounded(.down)), Int((visibleRange.upperBound / tileWidth).rounded(.up)))
        guard first <= last else { return [] }

        // Source seconds per tile (on average, for a ramp).
        let meanSpeed = clip.duration > .zero ? clip.sourceDuration.seconds / clip.duration.seconds : clip.speed
        let tileSourceSeconds = Double(tileWidth) / layout.pixelsPerSecond * meanSpeed
        let step = ThumbnailCache.quantum(forTileDuration: tileSourceSeconds, fps: fps)
        let url = MediaURLCache.shared.url(for: media)
        let lastFrame = media.duration - Time.frame(fps: fps)

        return (first...last).map { i in
            let x = CGFloat(i) * tileWidth
            let timelineTime = clip.start + layout.duration(forWidth: x + tileWidth / 2)
            let source = ThumbnailCache.quantize(clip.sourceTime(at: timelineTime), step: step)
                .clamped(.zero, max(lastFrame, .zero))
            return Tile(x: x, request: .init(mediaID: media.id, url: url, time: source, tolerance: Time(ticks: step.ticks / 2)))
        }
    }
}

/// Send to Playground (in Edit), or Promote to Edit and Apply Settings (in the Playground).
private struct PlaygroundClipMenuItems: View {
    let editor: EditorController
    let clip: Clip
    let targets: Set<UUID>

    var body: some View {
        if editor.isSandbox {
            Button("Promote to Edit as New Clip") { editor.promoteToEdit(targets) }
            if let original = editor.originalInProject(of: clip.id) {
                Button("Apply Settings to “\(original.name)” in Edit") {
                    editor.applySettingsToProject(from: clip.id, onto: original.id)
                }
            } else {
                Button("Apply Settings to Original in Edit") {}
                    .disabled(true)
            }
            if let selected = editor.selectedClipInProject {
                Button("Apply Settings to Selected Edit Clip (“\(selected.name)”)") {
                    editor.applySettingsToProject(from: clip.id, onto: selected.id)
                }
            }
        } else {
            Button(targets.count > 1 ? "Send \(targets.count) Clips to Playground" : "Send to Playground") {
                editor.sendToPlayground(targets)
            }
        }
    }
}

/// A generator clip's body: its experiment's icon and name on a stripe.
private struct GeneratorClipPreview: View {
    let generator: LabEffect
    let leading: CGFloat

    var body: some View {
        let experiment = ExperimentRegistry.experiment(generator.experimentID)
        HStack(spacing: 5) {
            Image(systemName: experiment?.symbolName ?? "flask")
            Text(experiment?.name ?? generator.experimentID)
                .lineLimit(1)
            if LabStatus.shared.errors[generator.id] != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.offlineBadge)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Theme.clipText.opacity(0.85))
        .padding(.leading, 6 + leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.sandboxMuted)
        .opacity(generator.isEnabled ? 1 : 0.5)
    }
}
