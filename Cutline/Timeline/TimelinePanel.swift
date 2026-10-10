import SwiftUI

/// Timeline container: header bar, ruler, track headers and the scrolling lanes.
///
/// The lanes live in a horizontal scroll view. The ruler sits outside it and
/// draws only the visible window using the reported scroll offset, which keeps
/// it pinned while scrolling vertically and avoids giant layers at deep zoom.
struct TimelinePanel: View {
    let editor: EditorController

    @State private var visibleRect: CGRect = .zero
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var pinchBase: Double?
    /// Furthest time reached by dragging the playhead past the right edge, so the
    /// content keeps growing and the drag can continue beyond the last clip.
    @State private var scrubExtent: Time = .zero

    private var layout: TimelineLayout {
        TimelineLayout(
            pixelsPerSecond: editor.pixelsPerSecond,
            tracks: editor.state.tracks,
            videoHeight: Theme.Metrics.laneHeight,
            audioHeight: Theme.Metrics.audioLaneHeight,
            textHeight: Theme.Metrics.textLaneHeight,
            spacing: Theme.Metrics.laneSpacing
        )
    }

    private var contentWidth: CGFloat {
        let end = max(editor.state.duration, editor.state.markers.map(\.time).max() ?? .zero, scrubExtent)
        let viewport = max(visibleRect.width, 400)
        return max(viewport, layout.x(for: end) + viewport * 0.6)
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineHeaderBar(editor: editor)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                Theme.background
                    .frame(width: Theme.Metrics.trackHeaderWidth)
                Rectangle().fill(Theme.border).frame(width: 1)
                RulerView(editor: editor, layout: layout, visibleRect: visibleRect)
            }
            .frame(height: Theme.Metrics.rulerHeight)
            .zIndex(2)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    TrackHeaderColumn(editor: editor, layout: layout)
                        .frame(width: Theme.Metrics.trackHeaderWidth)
                    Rectangle().fill(Theme.border).frame(width: 1)
                    ScrollView(.horizontal) {
                        TimelineLanes(editor: editor, layout: layout, visibleRect: visibleRect)
                            .frame(width: contentWidth, height: layout.lanesHeight, alignment: .topLeading)
                    }
                    .scrollPosition($scrollPosition)
                    .scrollIndicators(.visible)
                    .onScrollGeometryChange(for: CGRect.self) { geometry in
                        geometry.visibleRect
                    } action: { _, newValue in
                        visibleRect = newValue
                    }
                    .background {
                        PlayheadFollower(playback: editor.playback, layout: layout, visibleRect: visibleRect) { x in
                            scrollPosition.scrollTo(x: x)
                        }
                    }
                    .simultaneousGesture(pinchGesture)
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .background(Theme.background)

            if editor.workspace == .effects {
                Rectangle().fill(Theme.border).frame(height: 1)
                KeyframeLane(editor: editor, layout: layout, visibleRect: visibleRect)
            }
        }
        .background(Theme.background)
        .onChange(of: editor.pixelsPerSecond) { oldValue, newValue in
            keepAnchorInPlace(oldPixelsPerSecond: oldValue, newPixelsPerSecond: newValue)
        }
        .task(id: editor.playheadDragX != nil) {
            await autoScrollWhileDraggingPlayhead()
        }
    }

    /// While the playhead is dragged near or past either edge, keep scrolling and keep
    /// moving the playhead with it, so the drag continues beyond the visible area.
    private func autoScrollWhileDraggingPlayhead() async {
        let edge: CGFloat = 32
        while !Task.isCancelled, let pointer = editor.playheadDragX {
            let width = visibleRect.width
            var step: CGFloat = 0
            if width > 0, pointer > width - edge {
                step = min((pointer - (width - edge)) * 0.4 + 3, 80)
            } else if pointer < edge, visibleRect.minX > 0 {
                step = -min((edge - pointer) * 0.4 + 3, 80)
            }
            if step != 0 {
                let originX = max(0, visibleRect.minX + step)
                scrubExtent = max(scrubExtent, layout.time(forX: originX + width))
                scrollPosition.scrollTo(x: originX)
                let x = originX + pointer.clamped(to: 0...width)
                editor.scrub(to: layout.time(forX: x), layout: layout)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        // Keep the content long enough for where the playhead ended up.
        scrubExtent = max(editor.state.duration, editor.playback.currentTime)
    }

    /// Pinch to zoom around the pointer.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBase == nil {
                    pinchBase = editor.pixelsPerSecond
                    // The gesture reports locations in the scroll view's viewport.
                    editor.zoomAnchor = ZoomAnchor(
                        time: layout.time(forX: visibleRect.minX + value.startLocation.x),
                        viewportX: value.startLocation.x
                    )
                }
                editor.setZoom((pinchBase ?? editor.pixelsPerSecond) * value.magnification)
            }
            .onEnded { _ in
                pinchBase = nil
                editor.zoomAnchor = nil
            }
    }

    /// After a zoom change, scrolls so the anchor (pinch point, or the playhead
    /// when visible, or the view center) stays at the same screen position.
    private func keepAnchorInPlace(oldPixelsPerSecond: Double, newPixelsPerSecond: Double) {
        guard visibleRect.width > 0 else { return }
        let anchor: ZoomAnchor
        if let pinch = editor.zoomAnchor {
            anchor = pinch
        } else {
            let playheadX = CGFloat(editor.playback.currentTime.seconds * oldPixelsPerSecond)
            if playheadX >= visibleRect.minX && playheadX <= visibleRect.maxX {
                anchor = ZoomAnchor(time: editor.playback.currentTime, viewportX: playheadX - visibleRect.minX)
            } else {
                let midX = visibleRect.midX
                anchor = ZoomAnchor(time: Time(seconds: Double(midX) / oldPixelsPerSecond), viewportX: midX - visibleRect.minX)
            }
        }
        let targetX = max(0, CGFloat(anchor.time.seconds * newPixelsPerSecond) - anchor.viewportX)
        // Wait one pass so the content has its new width before scrolling.
        Task { @MainActor in
            scrollPosition.scrollTo(x: targetX)
        }
    }
}

// MARK: - Header bar

private struct TimelineHeaderBar: View {
    let editor: EditorController

    var body: some View {
        HStack(spacing: 6) {
            SectionLabel("Timeline")
            Spacer()
            IconButton(
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                help: editor.snappingEnabled ? "Snapping on" : "Snapping off",
                isActive: editor.snappingEnabled
            ) {
                editor.snappingEnabled.toggle()
            }
            Rectangle().fill(Theme.border).frame(width: 1, height: 16)
            IconButton(systemImage: "minus.magnifyingglass", help: "Zoom Out (⌘-)") { editor.zoomOut() }
            // Logarithmic zoom; hold ⌥ while dragging for fine steps.
            PrecisionSlider(
                value: log(editor.pixelsPerSecond),
                range: log(EditorController.zoomRange.lowerBound)...log(EditorController.zoomRange.upperBound),
                unitsPerPoint: (log(EditorController.zoomRange.upperBound) - log(EditorController.zoomRange.lowerBound)) / 110,
                onBegin: {},
                onChange: { editor.setZoom(exp($0)) },
                onEnd: {}
            )
            .frame(width: 110)
            IconButton(systemImage: "plus.magnifyingglass", help: "Zoom In (⌘+)") { editor.zoomIn() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 32)
    }
}

// MARK: - Track headers

private struct TrackHeaderColumn: View {
    let editor: EditorController
    let layout: TimelineLayout

    var body: some View {
        // Lay out from the current tracks: this view can update before its parent
        // after a track is deleted, and a stale layout would point at missing tracks.
        let layout = layout.with(tracks: editor.state.tracks)
        ZStack(alignment: .topLeading) {
            ForEach(layout.rows, id: \.trackID) { row in
                TrackHeader(editor: editor, trackID: row.trackID, height: row.height)
                    .frame(height: row.height)
                    .offset(y: row.y)
            }
            ForEach(layout.zones, id: \.kind) { zone in
                AddTrackButton(title: zone.kind.title, systemImage: zone.kind.symbolName) {
                    editor.addTrack(zone.kind)
                }
                .frame(height: zone.height)
                .padding(.horizontal, 4)
                .offset(y: zone.y)
            }
        }
        .frame(height: layout.lanesHeight, alignment: .topLeading)
    }
}

private struct AddTrackButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "plus")
                Text(title)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(isHovering ? Theme.raisedHover : Theme.raised, in: .rect(cornerRadius: 4))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Add \(title) Track")
        .onHover { isHovering = $0 }
    }
}

/// Resolves a track by its ID at draw time, so a header never refers to a track
/// position that no longer exists (deleting a track shifts the others).
private struct TrackHeader: View {
    let editor: EditorController
    let trackID: UUID
    let height: CGFloat

    var body: some View {
        if let index = editor.state.trackIndex(withID: trackID) {
            TrackHeaderContent(editor: editor, track: editor.state.tracks[index], index: index, height: height)
        }
    }
}

private struct TrackHeaderContent: View {
    let editor: EditorController
    let track: Track
    let index: Int
    let height: CGFloat

    @State private var isHovering = false

    private var defaultHeight: CGFloat {
        switch track.kind {
        case .video: Theme.Metrics.laneHeight
        case .audio: Theme.Metrics.audioLaneHeight
        case .text: Theme.Metrics.textLaneHeight
        }
    }

    private var isActive: Bool { editor.state.isTrackActive(index) }

    var body: some View {
        let compact = height < 46
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if !compact {
                    Image(systemName: track.kind.symbolName)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(track.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(track.isLocked || !isActive ? Theme.textTertiary : Theme.textSecondary)
                Spacer(minLength: 0)
                if compact { buttons }
            }
            if !compact { buttons }
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .topLeading)
        .padding(.top, compact ? 0 : 6)
        .background(Theme.raised, in: .rect(cornerRadius: 4))
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) { resizeHandle }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(muteTitle) { editor.toggleMute(trackAt: index) }
            Button(track.isSoloed ? "Unsolo" : "Solo") { editor.toggleSolo(trackAt: index) }
            Button(track.isLocked ? "Unlock Track" : "Lock Track") { editor.toggleLock(trackAt: index) }
            Menu("Track Height") {
                Button("Small") { editor.setTrackHeight(36, at: index) }
                Button("Medium") { editor.setTrackHeight(nil, at: index) }
                Button("Large") { editor.setTrackHeight(Double(defaultHeight) * 2, at: index) }
                Button("Extra Large") { editor.setTrackHeight(Track.heightRange.upperBound, at: index) }
            }
            Divider()
            Button("Delete Track", role: .destructive) { editor.deleteTrack(at: index) }
        }
    }

    private var muteTitle: String {
        track.kind.isVisual ? (track.isMuted ? "Show Track" : "Hide Track") : (track.isMuted ? "Unmute" : "Mute")
    }

    private var buttons: some View {
        HStack(spacing: 1) {
            if track.kind.isVisual {
                TrackToggle(systemImage: track.isMuted ? "eye.slash.fill" : "eye", isOn: track.isMuted,
                            tint: Theme.mutedTrack, help: muteTitle) { editor.toggleMute(trackAt: index) }
            } else {
                TrackToggle(letter: "M", isOn: track.isMuted, tint: Theme.mutedTrack, help: muteTitle) {
                    editor.toggleMute(trackAt: index)
                }
            }
            TrackToggle(letter: "S", isOn: track.isSoloed, tint: Theme.soloTrack, help: track.isSoloed ? "Unsolo" : "Solo") {
                editor.toggleSolo(trackAt: index)
            }
            TrackToggle(systemImage: track.isLocked ? "lock.fill" : "lock.open", isOn: track.isLocked,
                        tint: Theme.accent, help: track.isLocked ? "Unlock Track" : "Lock Track") {
                editor.toggleLock(trackAt: index)
            }
            TrackToggle(systemImage: "trash", isOn: false, tint: Theme.destructive, help: "Delete Track") {
                editor.deleteTrack(at: index)
            }
            .opacity(isHovering ? 1 : 0.4)
        }
    }

    /// Drag the bottom edge to change the track's height; double-click to reset it.
    private var resizeHandle: some View {
        Theme.background.opacity(0.001)
            .frame(height: 6)
            .contentShape(.rect)
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        editor.resizeTrack(at: index, by: value.translation.height, defaultHeight: defaultHeight)
                    }
                    .onEnded { _ in editor.endGesture("Change Track Height") }
            )
            .onTapGesture(count: 2) { editor.setTrackHeight(nil, at: index) }
            .help("Drag to resize the track. Double-click to reset.")
    }
}

/// Small square toggle used in track headers (M, S, lock, …).
private struct TrackToggle: View {
    var letter: String?
    var systemImage: String?
    let isOn: Bool
    let tint: Color
    let help: String
    let action: () -> Void

    init(letter: String, isOn: Bool, tint: Color, help: String, action: @escaping () -> Void) {
        self.letter = letter
        self.isOn = isOn
        self.tint = tint
        self.help = help
        self.action = action
    }

    init(systemImage: String, isOn: Bool, tint: Color, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.isOn = isOn
        self.tint = tint
        self.help = help
        self.action = action
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let letter {
                    Text(letter).font(.system(size: 10, weight: .bold))
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9.5, weight: .semibold))
                }
            }
            .foregroundStyle(isOn ? Theme.textOnAccent : (isHovering ? Theme.textPrimary : Theme.textSecondary))
            .frame(width: 20, height: 18)
            .background(isOn ? tint : (isHovering ? Theme.raisedHover : Theme.recessed), in: .rect(cornerRadius: 3))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}
