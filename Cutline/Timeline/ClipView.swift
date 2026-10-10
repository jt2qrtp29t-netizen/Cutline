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

    private var isAudio: Bool { kind == .audio }
    private var fill: Color {
        clip.isText ? Theme.textClipFill : (isAudio ? Theme.audioClipFill : Theme.clipFill)
    }
    private var border: Color {
        if clip.isText { return isSelected ? Theme.textClipBorderSelected : Theme.textClipBorder }
        if isAudio { return isSelected ? Theme.audioClipBorderSelected : Theme.audioClipBorder }
        return isSelected ? Theme.clipBorderSelected : Theme.clipBorder
    }

    var body: some View {
        let isOffline = !clip.isText && (media.map { !MediaURLCache.shared.isAvailable($0) } ?? true)
        VStack(spacing: 0) {
            label
            if let text = clip.text {
                TextClipPreview(text: text.string, leading: max(0, visibleRange.lowerBound))
            } else if let media, !isOffline {
                Group {
                    if isAudio {
                        Waveform(clip: clip, media: media, layout: layout, visibleRange: visibleRange)
                    } else {
                        Filmstrip(clip: clip, media: media, layout: layout, visibleRange: visibleRange, fps: editor.fps)
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
            if clip.speed != 1 {
                Text(String(format: "%.0f%%", clip.speed * 100))
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
        if editor.state.track(ofClip: clip.id)?.kind.isVisual == true {
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
                    if abs(clip.speed - speed) < 0.0001 {
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

/// Audio peaks drawn across the clip. Only the visible part is drawn, and the
/// height follows the clip's volume.
private struct Waveform: View {
    let clip: Clip
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
                let pps = layout.pixelsPerSecond
                let gain = min(clip.volume, 2)
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
                        let h = max(0.5, CGFloat(peak) * CGFloat(gain) * mid * 0.95)
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
                    if let image = cache.image(for: tile.request) {
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

        let tileSourceSeconds = Double(tileWidth) / layout.pixelsPerSecond * clip.speed
        let step = ThumbnailCache.quantum(forTileDuration: tileSourceSeconds, fps: fps)
        let url = MediaURLCache.shared.url(for: media)
        let lastFrame = media.duration - Time.frame(fps: fps)

        return (first...last).map { i in
            let x = CGFloat(i) * tileWidth
            let timelineTime = clip.start + layout.duration(forWidth: x + tileWidth / 2)
            let source = ThumbnailCache.quantize(clip.sourceTime(at: timelineTime), step: step)
                .clamped(.zero, max(lastFrame, .zero))
            return Tile(x: x, request: .init(mediaID: media.id, url: url, time: source))
        }
    }
}
