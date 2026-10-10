import SwiftUI
import UniformTypeIdentifiers

/// The scrollable content of the timeline: lane backgrounds, clips, and
/// overlays for snapping, drop previews and the playhead.
///
/// Clips are laid out in one flat layer (not inside their lanes) so a clip keeps
/// its view identity, and therefore its drag gesture, when moved between tracks.
struct TimelineLanes: View {
    let editor: EditorController
    let layout: TimelineLayout
    let visibleRect: CGRect

    /// Clips outside this window (plus a margin) are not instantiated at all.
    private var renderWindow: ClosedRange<CGFloat> {
        let margin = max(visibleRect.width, 300)
        return (visibleRect.minX - margin)...(visibleRect.maxX + margin)
    }

    private struct PlacedClip: Identifiable {
        let clip: Clip
        let track: Track
        let row: TimelineLayout.Row
        var id: UUID { clip.id }
    }

    private func placedClips(in layout: TimelineLayout) -> [PlacedClip] {
        let window = renderWindow
        var result: [PlacedClip] = []
        for row in layout.rows {
            let track = editor.state.tracks[row.trackIndex]
            for clip in track.clips {
                let minX = layout.x(for: clip.start)
                let maxX = layout.x(for: clip.end)
                // Selected clips stay alive so an in-progress drag is never torn down.
                if (maxX >= window.lowerBound && minX <= window.upperBound) || editor.selection.contains(clip.id) {
                    result.append(PlacedClip(clip: clip, track: track, row: row))
                }
            }
        }
        return result
    }

    var body: some View {
        // Lay out from the current tracks (see TrackHeaderColumn) so rows never
        // refer to a track that was just deleted.
        let layout = layout.with(tracks: editor.state.tracks)
        ZStack(alignment: .topLeading) {
            ForEach(layout.rows, id: \.trackID) { row in
                LaneBackground(editor: editor, layout: layout, isLocked: editor.state.tracks[row.trackIndex].isLocked,
                               originX: visibleRect.minX)
                    .frame(height: row.height)
                    .offset(y: row.y)
            }

            ForEach(layout.zones, id: \.kind) { zone in
                NewTrackZoneView(
                    zone: zone,
                    isActive: editor.newTrackHint == zone.kind || editor.dropPreview?.target == .newTrack(zone.kind)
                )
                .frame(height: zone.height)
                .offset(y: zone.y)
            }

            ForEach(placedClips(in: layout)) { placed in
                let x = layout.x(for: placed.clip.start)
                ClipView(
                    editor: editor,
                    clip: placed.clip,
                    kind: placed.track.kind,
                    isLocked: placed.track.isLocked,
                    media: editor.state.mediaItem(placed.clip.mediaID),
                    layout: layout,
                    isSelected: editor.selection.contains(placed.clip.id),
                    visibleRange: (visibleRect.minX - x)...(visibleRect.maxX - x)
                )
                .frame(width: max(layout.width(for: placed.clip.duration), 2), height: placed.row.height)
                // Muted, hidden or un-soloed clips and tracks are shown faded.
                .opacity(editor.state.isClipActive(placed.clip, onTrack: placed.row.trackIndex) ? 1 : 0.45)
                .offset(x: x, y: placed.row.y)
            }

            // Transitions sit over the middle of their cut, on top of the clips.
            ForEach(layout.rows, id: \.trackID) { row in
                let track = editor.state.tracks[row.trackIndex]
                ForEach(track.placedTransitions(), id: \.transition.id) { placed in
                    let width = max(layout.width(for: placed.duration), 14)
                    let height = min(max(row.height * 0.5, 16), 26)
                    TransitionMarker(editor: editor, placed: placed, isLocked: track.isLocked)
                        .frame(width: width, height: height)
                        .offset(x: layout.x(for: placed.cut) - width / 2, y: row.y + (row.height - height) / 2)
                }
            }

            if let target = editor.transitionDropTarget, let row = layout.row(forTrack: target.trackIndex) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.transitionDropTarget)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.transitionBorder, lineWidth: 2) }
                    .frame(width: 28, height: row.height)
                    .offset(x: layout.x(for: target.cut) - 14, y: row.y)
                    .allowsHitTesting(false)
            }

            ForEach(editor.state.markers) { marker in
                Rectangle()
                    .fill(Theme.marker(marker.color).opacity(0.35))
                    .frame(width: 1, height: layout.lanesHeight)
                    .offset(x: layout.x(for: marker.time))
                    .allowsHitTesting(false)
            }

            if let guide = editor.snapGuide {
                Rectangle()
                    .fill(Theme.snapGuide)
                    .frame(width: 1, height: layout.lanesHeight)
                    .offset(x: layout.x(for: guide))
                    .allowsHitTesting(false)
            }

            if let preview = editor.dropPreview {
                DropGhost(preview: preview, target: preview.target, layout: layout)
                if let paired = preview.pairedTrackIndex {
                    DropGhost(preview: preview, target: .track(paired), layout: layout)
                }
            }

            LanesPlayhead(editor: editor, playback: editor.playback, layout: layout, height: layout.lanesHeight,
                          originX: visibleRect.minX)
        }
        .coordinateSpace(.named(TimelineCoordinateSpace.lanes))
        .onDrop(
            of: [.cutlineMediaReference, .fileURL, .cutlineTransition],
            delegate: TimelineDropDelegate(editor: editor, layout: layout)
        )
    }
}

/// Empty lane space: clicking deselects, dragging scrubs the playhead.
private struct LaneBackground: View {
    let editor: EditorController
    let layout: TimelineLayout
    let isLocked: Bool
    let originX: CGFloat

    var body: some View {
        Theme.recessed
            .overlay {
                if isLocked { LockedHatch().allowsHitTesting(false) }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineCoordinateSpace.lanes))
                    .onChanged { value in
                        if value.translation == .zero {
                            editor.selection = []
                            editor.selectedTransition = nil
                        }
                        editor.dragPlayhead(viewportX: value.location.x - originX, contentX: value.location.x, layout: layout)
                    }
                    .onEnded { _ in editor.endPlayheadDrag() }
            )
    }
}

/// Diagonal stripes marking a locked lane.
struct LockedHatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 10
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(Theme.lockedHatch), lineWidth: 2)
        }
    }
}

/// The strip under each section where dropping or dragging a clip creates a new track.
private struct NewTrackZoneView: View {
    let zone: TimelineLayout.NewTrackZone
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(isActive ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .background(isActive ? Theme.dropTarget : Theme.background.opacity(0), in: .rect(cornerRadius: 4))
            .overlay(alignment: .leading) {
                Label(isActive ? "Release to create a new \(zone.kind.rawValue) track"
                               : "Drag a \(zone.kind.rawValue) clip here for a new track",
                      systemImage: "plus")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
                    .padding(.leading, 8)
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

/// Translucent preview of where a dropped clip will land.
private struct DropGhost: View {
    let preview: DropPreview
    let target: TimelineEditing.TrackTarget
    let layout: TimelineLayout

    private var placement: (y: CGFloat, height: CGFloat, kind: TrackKind)? {
        switch target {
        case .track(let index):
            return layout.row(forTrack: index).map { ($0.y, $0.height, $0.kind) }
        case .newTrack(let kind):
            return layout.zone(for: kind).map { ($0.y, $0.height, kind) }
        }
    }

    var body: some View {
        if let placement {
            let x = layout.x(for: preview.time)
            let ghostFill = switch placement.kind {
            case .video: Theme.clipGhost
            case .audio: Theme.audioClipGhost
            case .text: Theme.textClipGhost
            }
            let ghostBorder = switch placement.kind {
            case .video: Theme.clipBorderSelected
            case .audio: Theme.audioClipBorderSelected
            case .text: Theme.textClipBorderSelected
            }
            if preview.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: placement.height)
                    .offset(x: x, y: placement.y)
                    .allowsHitTesting(false)
            } else if let duration = preview.duration {
                RoundedRectangle(cornerRadius: Theme.Metrics.clipCornerRadius)
                    .fill(ghostFill)
                    .strokeBorder(ghostBorder,
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: max(layout.width(for: duration), 4), height: placement.height)
                    .offset(x: x, y: placement.y)
                    .allowsHitTesting(false)
            } else {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 2, height: placement.height)
                    .offset(x: x - 1, y: placement.y)
                    .allowsHitTesting(false)
            }
        }
    }
}
