import SwiftUI

/// Keyframes of the selected clip under the timeline: one row per parameter, aligned
/// with the timeline above. The Effects tab shows motion keyframes, the Color tab
/// color keyframes. Click a diamond to select it (⇧ adds),
/// drag to retime (selected keyframes move together), Delete removes.
struct KeyframeLane: View {
    let editor: EditorController
    let layout: TimelineLayout
    let visibleRect: CGRect

    static let rowHeight: CGFloat = 18

    /// The rows for this tab: animated parameters (and, in Effects, the one shown in
    /// the curve editor).
    func rows(for clip: Clip) -> [AnimatableProperty] { editor.laneProperties(for: clip) }

    /// The clip whose keyframes show: an audio clip in the Audio tab, otherwise a video or text clip.
    private var clip: Clip? {
        if editor.isSandbox { return editor.effectsClip }
        switch editor.workspace {
        case .audio: return editor.audioClip
        case .edit: return editor.editLaneClip
        default: return editor.effectsClip
        }
    }

    var body: some View {
        if let clip, !rows(for: clip).isEmpty {
            let rows = rows(for: clip)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(rows) { property in
                        Button {
                            if property.isMotion { editor.effectsProperty = property }
                        } label: {
                            Text(property.title)
                                .font(.system(size: 10, weight: property == editor.effectsProperty ? .semibold : .regular))
                                .foregroundStyle(property == editor.effectsProperty ? Theme.accent : Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 10)
                                .frame(height: Self.rowHeight)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: Theme.Metrics.trackHeaderWidth)
                Rectangle().fill(Theme.border).frame(width: 1)
                VStack(spacing: 0) {
                    ForEach(rows) { property in
                        KeyframeRow(editor: editor, clip: clip, property: property, layout: layout, originX: visibleRect.minX,
                                    visibleWidth: visibleRect.width)
                            .frame(height: Self.rowHeight)
                    }
                }
                .clipped()
            }
            .padding(.vertical, 4)
            .background(Theme.background)
        } else {
            Text(emptyMessage)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Theme.Metrics.trackHeaderWidth + 10)
                .frame(height: 26)
                .background(Theme.background)
        }
    }
}

extension KeyframeLane {
    private var emptyMessage: String {
        if editor.workspace == .audio && !editor.isSandbox {
            return clip == nil ? "Select an audio clip to see its volume and pan keyframes here."
                : "No clip keyframes yet. Click ◆ next to Volume or Pan to add one at the playhead."
        }
        if clip == nil { return "Select a video or text clip to see its keyframes here." }
        return editor.isSandbox ? "No keyframes yet. Click ◆ next to a control to add one at the playhead."
            : "No color keyframes yet. Click ◆ next to a color control to add one at the playhead."
    }
}

private struct KeyframeRow: View {
    let editor: EditorController
    let clip: Clip
    let property: AnimatableProperty
    let layout: TimelineLayout
    let originX: CGFloat
    let visibleWidth: CGFloat

    var body: some View {
        // The clip's span on this row, limited to what's on screen: a span wider than the
        // row would widen the row itself, which then gets centered and shifts every
        // diamond off to the side (long clips showed no keyframes at all).
        let start = max(layout.x(for: clip.start) - originX, -2)
        let end = min(layout.x(for: clip.end) - originX, visibleWidth + 2)
        ZStack(alignment: .leading) {
            Theme.recessed
            if end > start {
                Rectangle()
                    .fill(property == editor.effectsProperty ? Theme.accentMuted : Theme.raised)
                    .frame(width: max(end - start, 1), height: KeyframeLane.rowHeight - 6)
                    .offset(x: start)
            }
            ForEach(clip.animation.keyframes(for: property)) { frame in
                let ref = KeyframeRef(clipID: clip.id, property: property, keyframeID: frame.id)
                KeyframeDiamond(isFilled: true, isSelected: editor.selectedKeyframes.contains(ref), size: 10)
                    .frame(width: 16, height: KeyframeLane.rowHeight)
                    .contentShape(.rect)
                    .offset(x: layout.x(for: clip.start + frame.time) - originX - 8)
                    .onTapGesture { select(ref) }
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { drag in
                                if !editor.selectedKeyframes.contains(ref) { editor.selectedKeyframes = [ref] }
                                if property.isMotion { editor.effectsProperty = property }
                                editor.dragKeyframes(editor.selectedKeyframes, by: layout.duration(forWidth: drag.translation.width))
                            }
                            .onEnded { _ in
                                editor.endGesture(editor.selectedKeyframes.count > 1 ? "Move Keyframes" : "Move Keyframe")
                            }
                    )
                    .contextMenu {
                        Menu("Easing") {
                            ForEach(Easing.presets, id: \.self) { easing in
                                Button(easing.title) { editor.setEasing(easing, for: ref) }
                            }
                        }
                        Button("Delete Keyframe", role: .destructive) { editor.deleteKeyframes([ref]) }
                    }
                    .help("\(property.title): \(property.formatted(frame.value))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ ref: KeyframeRef) {
        if ref.property.isMotion { editor.effectsProperty = ref.property }
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if editor.selectedKeyframes.contains(ref) {
                editor.selectedKeyframes.remove(ref)
            } else {
                editor.selectedKeyframes.insert(ref)
            }
        } else {
            editor.selectedKeyframes = [ref]
        }
        // Jump the playhead to the keyframe, like clicking a marker.
        if let frame = editor.keyframe(ref) {
            editor.playback.pause()
            editor.playback.seek(to: clip.start + frame.time)
        }
    }
}

/// The selected audio track's keyframes (fader, pan and effect parameters) under the
/// timeline, one row per animated parameter. Click a diamond to go there, drag it to
/// retime, right-click to change its easing or delete it.
struct TrackKeyframeLane: View {
    let editor: EditorController
    let layout: TimelineLayout
    let visibleRect: CGRect

    var body: some View {
        if let track = editor.audioSettingsTrack {
            let keys = orderedKeys(track)
            if keys.isEmpty {
                Text("No keyframes on \(track.name) yet. Click ◆ next to its volume, pan or an effect setting to add one.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Theme.Metrics.trackHeaderWidth + 10)
                    .frame(height: 26)
                    .background(Theme.background)
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(keys, id: \.self) { key in
                            Text("\(track.name) · \(editor.trackParameterTitle(key, in: track))")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 10)
                                .frame(height: KeyframeLane.rowHeight)
                        }
                    }
                    .frame(width: Theme.Metrics.trackHeaderWidth)
                    Rectangle().fill(Theme.border).frame(width: 1)
                    VStack(spacing: 0) {
                        ForEach(keys, id: \.self) { key in
                            row(track, key)
                                .frame(height: KeyframeLane.rowHeight)
                        }
                    }
                    .clipped()
                }
                .padding(.vertical, 4)
                .background(Theme.background)
            }
        }
    }

    /// Volume and pan first, then effect parameters in chain order.
    private func orderedKeys(_ track: Track) -> [String] {
        let animated = track.audio.keyframes.filter { !$0.value.isEmpty }.map(\.key)
        var order: [String] = [AudioParameter.volume.id, AudioParameter.pan.id]
        for effect in track.audio.effects { order += effect.kind.parameters.map { effect.keyframeKey($0) } }
        return order.filter { animated.contains($0) }
    }

    private func row(_ track: Track, _ key: String) -> some View {
        let originX = visibleRect.minX
        return ZStack(alignment: .leading) {
            Theme.recessed
            ForEach(track.audio.keyframes[key] ?? []) { frame in
                KeyframeDiamond(isFilled: true, size: 10)
                    .frame(width: 16, height: KeyframeLane.rowHeight)
                    .contentShape(.rect)
                    .offset(x: layout.x(for: frame.time) - originX - 8)
                    .onTapGesture {
                        editor.playback.pause()
                        editor.playback.seek(to: frame.time)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { drag in
                                editor.moveTrackKeyframe(frame.id, key: key, track: track.id, by: layout.duration(forWidth: drag.translation.width))
                            }
                            .onEnded { _ in editor.endAudioAdjustment("Move Keyframe") }
                    )
                    .contextMenu {
                        Menu("Easing") {
                            ForEach(Easing.presets, id: \.self) { easing in
                                Button(easing.title) { editor.setTrackKeyframeEasing(easing, id: frame.id, key: key, track: track.id) }
                            }
                        }
                        Button("Delete Keyframe", role: .destructive) { editor.deleteTrackKeyframe(frame.id, key: key, track: track.id) }
                    }
                    .help(editor.trackParameterTitle(key, in: track))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
