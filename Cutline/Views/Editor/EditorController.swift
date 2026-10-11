import SwiftUI
import UniformTypeIdentifiers

/// Per-window editor state and the entry point for every user command.
/// Menu commands reach it through `FocusedValues.editor`.
@Observable
final class EditorController {
    let store: ProjectStore
    let playback = PlaybackController()

    var selection: Set<UUID> = [] {
        // Selecting clips deselects the transition.
        didSet { if !selection.isEmpty, selectedTransition != nil { selectedTransition = nil } }
    }
    /// Timeline zoom.
    var pixelsPerSecond: Double = 60
    var snappingEnabled = AppSettings.shared.snapByDefault
    var isImporting = false
    var alert: EditorAlert?

    /// Media currently being dragged out of the bin, so the timeline can show a ghost clip.
    var draggedMediaID: UUID?
    /// Where a drop onto the timeline would land. Set through `showDropPreview`.
    private(set) var dropPreview: DropPreview?
    @ObservationIgnored private var dropPreviewExpiry: Task<Void, Never>?
    /// Position currently snapped to during a drag, drawn as a guide line.
    var snapGuide: Time?
    /// Set during pinch zoom so the timeline keeps the time under the pointer fixed.
    var zoomAnchor: ZoomAnchor?
    /// A marker being created (⌘M); not yet part of the project.
    var markerDraft: Marker?
    /// Marker whose edit popover is open on the ruler.
    var editingMarkerID: UUID?
    var lastMarkerColor: MarkerColor = .orange
    /// Kind of track that will be created if the current drag is released.
    var newTrackHint: TrackKind?
    /// Speed / duration dialog for a clip.
    var clipDialog: ClipDialog?
    /// Which workspace tab is showing.
    var workspace: Workspace = .edit {
        didSet {
            guard !isSandbox, workspace != oldValue else { return }
            let wasPlayground = oldValue == .playground || (oldValue == .export && exportSource == .playground)
            if showsPlaygroundTimeline {
                // Only one preview plays at a time.
                playback.pause()
                isHoldingBefore = false
                _ = ensurePlayground()
            } else if wasPlayground {
                playground?.deactivate()
            }
        }
    }
    /// True for the Playground's editor, which works on scratch state only.
    @ObservationIgnored var isSandbox = false
    /// For the Playground's editor: the project editor it belongs to.
    @ObservationIgnored weak var owner: EditorController?
    /// Which adjustments the Playground's left panel shows.
    var sandboxPanel: SandboxPanel = .adjust
    /// This project's Playground, created the first time it's needed.
    var playground: PlaygroundSession?
    /// The project's file, used to find its Playground (set by the window).
    @ObservationIgnored var projectFileURL: URL?
    /// Where Playgrounds are saved (tests use a temporary folder).
    @ObservationIgnored var playgroundFolder = PlaygroundFile.folder

    /// The timeline the Export tab exports.
    var exportSource: ExportSource = .edit {
        didSet {
            if exportSource == .playground { _ = ensurePlayground() }
            // Only the source being looked at plays.
            if exportSource != oldValue { (oldValue == .edit ? playback : playground?.editor.playback)?.pause() }
        }
    }

    /// Whether the Playground's timeline is the one on screen.
    var showsPlaygroundTimeline: Bool {
        workspace == .playground || (workspace == .export && exportSource == .playground)
    }

    /// The editor that commands act on: the Playground's while its timeline is showing.
    var activeEditor: EditorController {
        showsPlaygroundTimeline ? (playground?.editor ?? self) : self
    }

    /// Opens (or creates) this project's Playground.
    func ensurePlayground() -> PlaygroundSession {
        if let playground { return playground }
        let key = PlaygroundFile.key(projectID: state.id, fileURL: projectFileURL)
        let session = PlaygroundSession(key: key, projectSettings: state.settings, folder: playgroundFolder)
        session.editor.owner = self
        playground = session
        return session
    }
    /// The parameter shown in the curve editor and highlighted in the Effects panel.
    var effectsProperty: AnimatableProperty = .positionX
    /// The audio track the Audio tab's settings show (picked in the mixer).
    var selectedAudioTrackID: UUID?
    /// What the Audio tab is busy with ("Normalizing…"), and the last result to show.
    var audioActivity: String?
    var audioMessage: String?
    var selectedKeyframes: Set<KeyframeRef> = []
    /// The grade on the clipboard (Copy Grade / Paste Grade).
    var copiedGrade: CopiedGrade?
    /// Before/after: the Before toggle in the Color tab, and holding B.
    var bypassGrade = false { didSet { updateGradeBypass() } }
    var isHoldingBefore = false { didSet { updateGradeBypass() } }
    /// The transition selected on the timeline, if any.
    var selectedTransition: UUID?
    /// Transition being dragged from the Effects tab, and the cut it would land on.
    var draggedTransition: TransitionKind?
    var transitionDropTarget: TransitionDropTarget?
    /// Length used for new transitions (the last one chosen; also set in Parameters).
    var transitionDuration: Double {
        get { AppSettings.shared.transitionLength }
        set { AppSettings.shared.transitionLength = newValue }
    }

    static let zoomRange: ClosedRange<Double> = 2...1200

    init(store: ProjectStore) {
        self.store = store
    }

    var state: ProjectState { store.state }
    var settings: ProjectSettings { store.state.settings }
    var fps: Int { store.state.settings.frameRate }

    /// Selected clips that still exist (undo can remove clips out from under the selection).
    var selectedClips: [Clip] {
        state.allClips.filter { selection.contains($0.id) }
    }

    /// Clip IDs that may be selected: those on unlocked tracks.
    var selectableClipIDs: Set<UUID> {
        Set(state.tracks.filter { !$0.isLocked }.flatMap(\.clips).map(\.id))
    }

    // MARK: Zoom

    /// Hold ⌥ for small zoom steps.
    private var zoomStep: Double { NSEvent.modifierFlags.contains(.option) ? 1.08 : 1.5 }
    func zoomIn() { setZoom(pixelsPerSecond * zoomStep) }
    func zoomOut() { setZoom(pixelsPerSecond / zoomStep) }

    func setZoom(_ value: Double) {
        pixelsPerSecond = value.clamped(to: Self.zoomRange)
    }

    // MARK: Drop preview

    /// Shows (or refreshes) the drop ghost. AppKit keeps sending updates while a drag
    /// hovers the timeline; if they stop without an exit or drop (the drag ended
    /// elsewhere or was cancelled), the ghost expires instead of staying on screen.
    func showDropPreview(_ preview: DropPreview) {
        if dropPreview != preview { dropPreview = preview }
        dropPreviewExpiry?.cancel()
        dropPreviewExpiry = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            dropPreview = nil
        }
    }

    func clearDropPreview() {
        dropPreviewExpiry?.cancel()
        dropPreviewExpiry = nil
        dropPreview = nil
    }

    // MARK: Snapping

    /// Snaps a drop position so the clip's start (or end) lands on a nearby edge.
    func snappedDropTime(_ time: Time, duration: Time?, layout: TimelineLayout) -> Time {
        let framed = time.snappedToFrame(fps: fps)
        guard snappingEnabled else { return framed }
        let threshold = layout.duration(forWidth: AppSettings.shared.snapDistance)
        let points = SnapEngine.points(in: state, playhead: snapPlayhead, excluding: [])
        let edges = [Time.zero] + (duration.map { [$0] } ?? [])
        if let snap = SnapEngine.snap(edges: edges.map { framed + $0 }, to: points, threshold: threshold) {
            return framed + snap.offset
        }
        return framed
    }

    var snapPlayhead: Time? { playback.currentTime }

    // MARK: Transport

    func togglePlayback() {
        endTextEditing()
        playback.togglePlayback()
    }

    /// Takes keyboard focus away from text fields (committing their edits), so
    /// single-key shortcuts like Space reach the editor again.
    func endTextEditing() {
        guard let window = NSApp.keyWindow, window.firstResponder is NSTextView else { return }
        window.makeFirstResponder(nil)
    }
    func goToStart() { playback.pause(); playback.seek(to: .zero) }
    func goToEnd() { playback.pause(); playback.seek(to: state.duration) }

    /// Moves the playhead while scrubbing, snapping to edits and markers when enabled.
    func scrub(to time: Time, layout: TimelineLayout) {
        if playback.isPlaying { playback.pause() }
        var target = max(time, .zero).snappedToFrame(fps: fps)
        if snappingEnabled {
            let threshold = layout.duration(forWidth: AppSettings.shared.snapDistance)
            let points = SnapEngine.points(in: state, playhead: nil, excluding: [])
            if let snap = SnapEngine.snap(edges: [target], to: points, threshold: threshold) {
                target += snap.offset
            }
        }
        playback.seek(to: target, audible: AppSettings.shared.scrubAudio)
    }

    /// Pointer position (relative to the visible left edge of the timeline) while the
    /// playhead is being dragged; the timeline auto-scrolls when it nears an edge.
    var playheadDragX: CGFloat?

    /// Where an Option (frame-by-frame) drag started: pointer position and playhead time.
    @ObservationIgnored private var fineScrubAnchor: (x: CGFloat, time: Time)?
    var isFineScrubbing: Bool { fineScrubAnchor != nil }
    /// Pointer travel per frame while Option-dragging, whatever the zoom (set in Parameters).
    static var fineScrubPointsPerFrame: CGFloat { AppSettings.shared.fineScrubPointsPerFrame }

    /// Drags the playhead. `viewportX` is the pointer relative to the visible area,
    /// `contentX` its position on the timeline. Holding Option moves the playhead one
    /// frame per few points of pointer travel instead of following the pointer.
    func dragPlayhead(viewportX: CGFloat, contentX: CGFloat, layout: TimelineLayout,
                      modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        if playheadDragX == nil { endTextEditing() }
        playheadDragX = viewportX
        guard modifiers.contains(.option) else {
            fineScrubAnchor = nil
            scrub(to: layout.time(forX: contentX), layout: layout)
            return
        }
        if playback.isPlaying { playback.pause() }
        let anchor = fineScrubAnchor ?? (contentX, playback.currentTime.snappedToFrame(fps: fps))
        fineScrubAnchor = anchor
        let frames = Int(((contentX - anchor.x) / Self.fineScrubPointsPerFrame).rounded(.towardZero))
        let target = anchor.time + Time(seconds: Double(frames) / Double(fps))
        playback.seek(to: max(target, .zero).snappedToFrame(fps: fps), audible: AppSettings.shared.scrubAudio)
    }

    func endPlayheadDrag() {
        playheadDragX = nil
        fineScrubAnchor = nil
    }

    // MARK: Clip gestures

    /// Live-updates a clip move. The first call starts the gesture; `endGesture` commits it.
    /// - Parameter pointerY: pointer position in lane coordinates, used to pick the target
    ///   track. Dragging below the last track of the clip's kind creates a new track.
    func dragClips(grabbing clipID: UUID, translationX: CGFloat, pointerY: CGFloat, layout: TimelineLayout) {
        if !store.isLiveEditing {
            store.beginLiveEdit()
            if !selection.contains(clipID) { select(clipID) }
        }
        guard let base = store.liveBase, let sourceTrack = base.trackIndex(ofClip: clipID),
              !base.isClipLocked(clipID) else { return }
        let ids = selection.contains(clipID) ? selection : base.linkedGroup(of: clipID)
        let moving = base.allClips.filter { ids.contains($0.id) && !$0.isLocked }

        var delta = layout.duration(forWidth: translationX).snappedToFrame(fps: fps)
        // Resolve the pointer against the layout as it was when the drag began, so a
        // track created during the drag doesn't shift the target under the pointer.
        let kind = base.tracks[sourceTrack].kind
        let trackChange: TimelineEditing.TrackChange
        switch layout.with(tracks: base.tracks).target(forY: pointerY, kind: kind) {
        case .track(let index):
            trackChange = .ordinalDelta(base.ordinal(ofTrack: index) - base.ordinal(ofTrack: sourceTrack))
        case .newTrack:
            trackChange = .newTrack
        }
        newTrackHint = trackChange == .newTrack ? kind : nil

        snapGuide = nil
        if snappingEnabled {
            let edges = moving.flatMap { [$0.start + delta, $0.end + delta] }
            let points = SnapEngine.points(in: base, playhead: playback.currentTime, excluding: ids)
            let threshold = layout.duration(forWidth: AppSettings.shared.snapDistance)
            if let snap = SnapEngine.snap(edges: edges, to: points, threshold: threshold) {
                delta += snap.offset
                snapGuide = snap.target
            }
        }
        store.liveEdit { state in
            TimelineEditing.move(ids, by: delta, trackChange: trackChange, kind: kind, in: &state)
        }
    }

    /// Live-updates a trim of one clip edge. Linked clips whose same edge lines up
    /// with this one are trimmed along with it.
    func trimClip(_ clipID: UUID, edge: ClipEdge, translationX: CGFloat, layout: TimelineLayout) {
        if !store.isLiveEditing {
            store.beginLiveEdit()
            select(clipID)
        }
        guard let base = store.liveBase, let clip = base.clip(clipID), !base.isClipLocked(clipID) else { return }
        let original = edge == .leading ? clip.start : clip.end
        var target = (original + layout.duration(forWidth: translationX)).snappedToFrame(fps: fps)

        snapGuide = nil
        if snappingEnabled {
            let points = SnapEngine.points(in: base, playhead: playback.currentTime, excluding: [clipID])
            let threshold = layout.duration(forWidth: AppSettings.shared.snapDistance)
            if let snap = SnapEngine.snap(edges: [target], to: points, threshold: threshold) {
                target += snap.offset
                snapGuide = snap.target
            }
        }
        let partners = base.linkedGroup(of: clipID).filter { id in
            guard let other = base.clip(id) else { return false }
            return edge == .leading ? other.start == clip.start : other.end == clip.end
        }
        store.liveEdit { state in
            for id in partners { TimelineEditing.trim(id, edge: edge, to: target, in: &state) }
        }
        // Hide the guide if the trim was limited by the media or a neighbour.
        if let snapGuide, let trimmed = store.state.clip(clipID),
           (edge == .leading ? trimmed.start : trimmed.end) != snapGuide {
            self.snapGuide = nil
        }
    }

    func endGesture(_ actionName: String) {
        store.commitLiveEdit(actionName)
        snapGuide = nil
        newTrackHint = nil
    }

    // MARK: Selection

    /// Selects a clip together with the clips linked to it. Option selects just the clip;
    /// Shift or Command add to / remove from the selection.
    func select(_ clipID: UUID, modifiers: NSEvent.ModifierFlags = []) {
        endTextEditing()
        selectedTransition = nil
        let group = modifiers.contains(.option) ? [clipID] : state.linkedGroup(of: clipID)
        if modifiers.contains(.shift) || modifiers.contains(.command) {
            if selection.contains(clipID) {
                selection.subtract(group)
            } else {
                selection.formUnion(group)
            }
        } else {
            selection = group
        }
    }

    // MARK: Editing commands

    /// Cuts the selected clips at the playhead, or every clip under it when nothing is selected.
    func bladeAtPlayhead() {
        let time = playback.currentTime
        let targets = selection
        var created: [UUID] = []
        store.edit("Blade") { state in
            created = TimelineEditing.blade(at: time, clips: targets, in: &state)
        }
        if created.isEmpty { NSSound.beep() }
    }

    func deleteSelection() {
        // A selected transition goes first, then selected keyframes in the lane (any tab).
        if let transition = selectedTransition {
            deleteTransition(transition)
            return
        }
        let keyframes = visibleSelectedKeyframes
        if !keyframes.isEmpty {
            deleteKeyframes(keyframes)
            return
        }
        let ids = selection
        guard !ids.isEmpty else { NSSound.beep(); return }
        store.edit(ids.count == 1 ? "Delete Clip" : "Delete Clips") { state in
            TimelineEditing.delete(ids, in: &state)
        }
        selection = []
    }

    // MARK: Links, locks, speed and duration

    /// The selected clips that can be acted on (their track isn't locked).
    var actionableSelection: Set<UUID> {
        selection.intersection(selectableClipIDs)
    }

    /// Clips a context-menu command applies to: the selection if the clicked clip is
    /// part of it, otherwise the clicked clip and its linked clips.
    func contextTargets(for clipID: UUID) -> Set<UUID> {
        selection.contains(clipID) ? actionableSelection : state.linkedGroup(of: clipID)
    }

    func isLinked(_ ids: Set<UUID>) -> Bool {
        ids.contains { state.clip($0)?.linkID != nil }
    }

    func canToggleLink(_ ids: Set<UUID>) -> Bool {
        isLinked(ids) || ids.count > 1
    }

    var selectionIsLinked: Bool { isLinked(actionableSelection) }
    var canToggleLink: Bool { canToggleLink(actionableSelection) }

    /// Links the clips, or unlinks them if any are linked (⌥⌘L).
    func toggleLink(_ ids: Set<UUID>) {
        if isLinked(ids) {
            store.edit("Unlink Clips") { TimelineEditing.unlink(ids, in: &$0) }
        } else if ids.count > 1 {
            store.edit("Link Clips") { TimelineEditing.link(ids, in: &$0) }
            selection = ids
        } else {
            NSSound.beep()
        }
    }

    func toggleLinkSelection() { toggleLink(actionableSelection) }

    func isLocked(_ ids: Set<UUID>) -> Bool {
        !ids.isEmpty && ids.allSatisfy { state.clip($0)?.isLocked == true }
    }

    var selectionIsLocked: Bool { isLocked(actionableSelection) }

    func toggleLock(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { NSSound.beep(); return }
        let locking = !isLocked(ids)
        store.edit(locking ? "Lock Clip" : "Unlock Clip") { TimelineEditing.setLocked(locking, clips: ids, in: &$0) }
    }

    func toggleLockSelection() { toggleLock(actionableSelection) }

    func areMuted(_ ids: Set<UUID>) -> Bool {
        !ids.isEmpty && ids.allSatisfy { state.clip($0)?.isMuted == true }
    }

    func areSoloed(_ ids: Set<UUID>) -> Bool {
        !ids.isEmpty && ids.allSatisfy { state.clip($0)?.isSoloed == true }
    }

    /// Mutes the clips, or unmutes them if they're all muted already.
    func toggleMute(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { NSSound.beep(); return }
        let muting = !areMuted(ids)
        store.edit(muting ? "Mute Clip" : "Unmute Clip") { state in
            for id in ids { state.updateClip(id) { $0.isMuted = muting } }
        }
    }

    /// Solos the clips, or unsolos them if they're all soloed already.
    func toggleSolo(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { NSSound.beep(); return }
        let soloing = !areSoloed(ids)
        store.edit(soloing ? "Solo Clip" : "Unsolo Clip") { state in
            for id in ids { state.updateClip(id) { $0.isSoloed = soloing } }
        }
    }

    func setSpeed(_ speed: Double, of ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.edit("Change Speed") { state in
            for id in ids { TimelineEditing.setSpeed(speed, for: id, in: &state) }
        }
    }

    /// Sets the length of clips by moving their out-points.
    func setDuration(_ duration: Time, of ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.edit("Change Duration") { state in
            for id in ids { TimelineEditing.setDuration(duration, for: id, in: &state) }
        }
    }

    func deleteClips(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.edit(ids.count == 1 ? "Delete Clip" : "Delete Clips") { TimelineEditing.delete(ids, in: &$0) }
        selection.subtract(ids)
    }

    func blade(_ ids: Set<UUID>) {
        let time = playback.currentTime
        var created: [UUID] = []
        store.edit("Blade") { created = TimelineEditing.blade(at: time, clips: ids, in: &$0) }
        if created.isEmpty { NSSound.beep() }
    }

    func showClipDialog(_ kind: ClipDialog.Kind, for clipID: UUID) {
        clipDialog = ClipDialog(kind: kind, clipIDs: contextTargets(for: clipID), clipID: clipID)
    }

    /// Opens the dialog for the selection (menu bar).
    func showClipDialogForSelection(_ kind: ClipDialog.Kind) {
        guard let first = actionableSelection.first else { NSSound.beep(); return }
        clipDialog = ClipDialog(kind: kind, clipIDs: actionableSelection, clipID: first)
    }

    func selectAllClips() {
        selection = Set(state.allClips.map(\.id))
    }

    // MARK: Markers

    /// Begins adding a marker at the playhead. The marker is shown immediately and
    /// committed (as one undo step) when its popover is dismissed.
    func addMarkerAtPlayhead() {
        if let draft = markerDraft { commitMarkerDraft(draft) }
        let n = state.markers.count + 1
        markerDraft = Marker(
            id: UUID(),
            time: playback.currentTime.snappedToFrame(fps: fps),
            name: "Marker \(n)",
            color: lastMarkerColor
        )
        editingMarkerID = nil
    }

    func commitMarkerDraft(_ marker: Marker) {
        markerDraft = nil
        lastMarkerColor = marker.color
        store.edit("Add Marker") { state in
            state.markers.append(marker)
            state.markers.sort { $0.time < $1.time }
        }
    }

    func cancelMarkerDraft() {
        markerDraft = nil
    }

    func updateMarker(_ marker: Marker) {
        lastMarkerColor = marker.color
        store.edit("Edit Marker") { state in
            state.updateMarker(marker.id) { $0 = marker }
        }
    }

    func deleteMarker(_ id: UUID) {
        if editingMarkerID == id { editingMarkerID = nil }
        store.edit("Delete Marker") { state in
            state.markers.removeAll { $0.id == id }
        }
    }

    func jump(to marker: Marker) {
        playback.pause()
        playback.seek(to: marker.time, audible: true)
    }

    func goToMarker(next: Bool) {
        let now = playback.currentTime
        let target = next
            ? state.markers.first { $0.time > now }
            : state.markers.last { $0.time < now }
        if let target { jump(to: target) } else { NSSound.beep() }
    }

    // MARK: Inspector adjustments

    /// Applies a clip change. While a slider drag is in progress (`beginAdjustment`
    /// was called) the change is live; otherwise it is a single undoable edit.
    /// - Parameter coalesce: merge rapid repeats (typing, dragging a color well) into one undo step.
    func adjustClip(_ id: UUID, actionName: String, coalesce: Bool = false, _ body: @escaping (inout Clip) -> Void) {
        guard !state.isClipLocked(id) else { NSSound.beep(); return }
        if store.isLiveEditing {
            store.liveEdit { $0.updateClip(id, body) }
        } else {
            store.edit(actionName, coalescingKey: coalesce ? "\(id)/\(actionName)" : nil) { $0.updateClip(id, body) }
        }
    }

    // MARK: Start / end animation

    /// The first and (if animated) last keyframe values of a parameter, for the
    /// start → end rows in the inspector.
    func animationEnds(of property: AnimatableProperty, in clip: Clip) -> (start: Double, end: Double?) {
        let frames = clip.animation.keyframes(for: property)
        guard let first = frames.first else { return (clip[keyPath: property.keyPath], nil) }
        return (first.value, frames.count > 1 ? frames.last?.value : nil)
    }

    func setAnimationStart(_ property: AnimatableProperty, of id: UUID, to value: Double, actionName: String) {
        adjustClip(id, actionName: actionName) { clip in
            if var frames = clip.animation.keyframes[property], !frames.isEmpty {
                frames[0].value = value
                clip.animation.keyframes[property] = frames
            } else {
                clip[keyPath: property.keyPath] = value
            }
        }
    }

    /// Sets the value at the clip's last frame, making a start → end animation; nil
    /// removes the animation and keeps the start value.
    func setAnimationEnd(_ property: AnimatableProperty, of id: UUID, to value: Double?, actionName: String) {
        adjustClip(id, actionName: actionName) { clip in
            let start = clip.animation.keyframes(for: property).first?.value ?? clip[keyPath: property.keyPath]
            guard let value else {
                clip.animation.keyframes[property] = nil
                clip[keyPath: property.keyPath] = start
                return
            }
            let last = max(clip.duration - Time(ticks: 1), .zero)
            clip.animation.keyframes[property] = [Keyframe(time: .zero, value: start), Keyframe(time: last, value: value)]
        }
    }

    // MARK: Text

    /// A text clip whose text field should take focus when its panel appears.
    var pendingTextFocus: UUID?

    /// Adds a 5-second text clip at the playhead on the first text track that's free
    /// there (T1, then T2, …), creating a text track if needed.
    func addTextClip() {
        let clip = Clip.text(at: playback.currentTime.snappedToFrame(fps: fps), duration: Time(seconds: 5))
        var placed = false
        store.edit("Add Text") { state in
            let free = state.trackIndices(of: .text).first { index in
                !state.tracks[index].isLocked && !state.tracks[index].clips.contains { $0.range.overlaps(clip.range) }
            }
            placed = TimelineEditing.insert(clip, onTrack: free ?? state.appendTrack(.text), in: &state)
        }
        guard placed else { NSSound.beep(); return }
        selection = [clip.id]
        pendingTextFocus = clip.id
    }

    /// Changes the speed of a clip and the clips linked to it.
    func setSpeed(_ speed: Double, for id: UUID) {
        let group = state.linkedGroup(of: id)
        let apply: (inout ProjectState) -> Void = { state in
            for clip in group { TimelineEditing.setSpeed(speed, for: clip, in: &state) }
        }
        if store.isLiveEditing {
            store.liveEdit(apply)
        } else {
            store.edit("Change Speed", apply)
        }
    }

    /// Speed's main slider: the constant speed, or (unlocked) the first keyframe of the ramp.
    func setSpeedStart(_ value: Double, of id: UUID) {
        guard let clip = state.clip(id) else { return }
        if clip.hasSpeedRamp {
            adjustClip(id, actionName: "Change Speed") { c in
                guard var frames = c.animation.keyframes[.speed], !frames.isEmpty else { return }
                frames[0].value = value.clamped(to: TimeRemap.range)
                c.animation.keyframes[.speed] = frames
            }
        } else {
            setSpeed(value, for: id)
        }
    }

    /// Speed's End slider. Unlocking (the first value) starts the ramp with End equal to
    /// Start, so nothing changes until End moves; nil locks back to a constant speed (the
    /// start speed), and the End value isn't kept, exactly like Position.
    func setSpeedEnd(_ value: Double?, of id: UUID) {
        adjustClip(id, actionName: value == nil ? "Lock Speed" : "Change Speed") { c in
            let frames = c.animation.keyframes(for: .speed)
            let start = frames.first?.value ?? c.speed
            guard let value else {
                c.animation.keyframes[.speed] = nil
                c.speed = start
                return
            }
            let v = value.clamped(to: TimeRemap.range)
            if frames.count >= 2 {
                var updated = frames
                updated[updated.count - 1].value = v
                c.animation.keyframes[.speed] = updated
            } else {
                let last = max(c.duration - Time(ticks: 1), .zero)
                c.animation.keyframes[.speed] = [Keyframe(time: .zero, value: start), Keyframe(time: last, value: v)]
            }
        }
    }

    func beginAdjustment() { store.beginLiveEdit() }
    func endAdjustment(_ actionName: String) { store.commitLiveEdit(actionName) }

    // MARK: Tracks

    func addTrack(_ kind: TrackKind) {
        store.edit("Add \(kind.title) Track") { state in
            state.appendTrack(kind)
        }
    }

    /// Deletes a track and the clips on it (undoable).
    func deleteTrack(at index: Int) {
        guard state.tracks.indices.contains(index) else { return }
        let clipIDs = Set(state.tracks[index].clips.map(\.id))
        let trackID = state.tracks[index].id
        // Removing a ducking voice or game track also clears the ducking setup (pruned with the edit).
        store.edit("Delete Track") { state in
            state.tracks.remove(at: index)
        }
        selection.subtract(clipIDs)
        if selectedAudioTrackID == trackID { selectedAudioTrackID = nil }
    }

    func toggleMute(trackAt index: Int) {
        guard state.tracks.indices.contains(index) else { return }
        let track = state.tracks[index]
        let name = track.kind.isVisual ? (track.isMuted ? "Show Track" : "Hide Track")
                                        : (track.isMuted ? "Unmute Track" : "Mute Track")
        store.edit(name) { $0.tracks[index].isMuted.toggle() }
    }

    func toggleSolo(trackAt index: Int) {
        guard state.tracks.indices.contains(index) else { return }
        store.edit(state.tracks[index].isSoloed ? "Unsolo Track" : "Solo Track") { $0.tracks[index].isSoloed.toggle() }
    }

    /// Live-updates a track's height while its header edge is dragged.
    func resizeTrack(at index: Int, by delta: CGFloat, defaultHeight: CGFloat) {
        if !store.isLiveEditing { store.beginLiveEdit() }
        guard let base = store.liveBase, base.tracks.indices.contains(index) else { return }
        let start = base.tracks[index].height ?? Double(defaultHeight)
        let height = (start + Double(delta)).clamped(to: Track.heightRange).rounded()
        store.liveEdit { $0.tracks[index].height = height }
    }

    func setTrackHeight(_ height: Double?, at index: Int) {
        guard state.tracks.indices.contains(index) else { return }
        store.edit("Change Track Height") { $0.tracks[index].height = height?.clamped(to: Track.heightRange) }
    }

    func toggleLock(trackAt index: Int) {
        guard state.tracks.indices.contains(index) else { return }
        let locking = !state.tracks[index].isLocked
        store.edit(locking ? "Lock Track" : "Unlock Track") { state in
            state.tracks[index].isLocked = locking
        }
        if locking { selection.subtract(state.tracks[index].clips.map(\.id)) }
    }

    // MARK: Import

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImporter.importableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Import"
        panel.message = "Choose video or audio files to add to the media bin."
        guard panel.runModal() == .OK else { return }
        importMedia(panel.urls)
    }

    /// Imports files into the bin. Files already in the project are not added twice.
    func importMedia(_ urls: [URL]) {
        Task { _ = await importedItems(for: urls, actionName: "Import Media") }
    }

    /// Imports files (if needed) and places them one after another on a track.
    func importAndPlace(_ urls: [URL], on target: TimelineEditing.TrackTarget, at time: Time) {
        Task {
            let result = await loadMedia(urls)
            guard !result.items.isEmpty else { return }
            var created: [UUID] = []
            var placed: [MediaItem] = []
            store.edit(result.items.count == 1 ? "Add Clip" : "Add Clips") { state in
                var cursor = time
                for item in result.items {
                    let media = Self.existingOrAppend(item, in: &state)
                    placed.append(media)
                    // After the first file, later files follow on the track it went to.
                    let ids = TimelineEditing.place(media, at: cursor, on: Self.resolved(target, after: created, in: state), in: &state)
                    created += ids
                    cursor = ids.compactMap { state.clip($0)?.end }.max() ?? cursor
                }
            }
            GeneratedMediaLibrary.shared.createAutomatically(for: placed)
            if created.isEmpty { NSSound.beep() } else { selection = Set(created) }
        }
    }

    /// Places a bin item on the timeline. Files with both picture and sound become
    /// separate, unlinked video and audio clips.
    func placeMedia(_ mediaID: UUID, on target: TimelineEditing.TrackTarget, at time: Time) {
        guard let media = state.mediaItem(mediaID) else { return }
        var created: [UUID] = []
        store.edit("Add Clip") { state in
            created = TimelineEditing.place(media, at: time, on: target, in: &state)
        }
        if created.isEmpty { NSSound.beep() } else { selection = Set(created) }
    }

    func removeMedia(_ ids: Set<UUID>) {
        store.edit(ids.count == 1 ? "Remove Media" : "Remove Media Items") { state in
            TimelineEditing.removeMedia(ids, in: &state)
        }
    }

    private func importedItems(for urls: [URL], actionName: String) async -> [MediaItem] {
        let result = await loadMedia(urls)
        var items: [MediaItem] = []
        store.edit(actionName) { state in
            items = result.items.map { Self.existingOrAppend($0, in: &state) }
        }
        GeneratedMediaLibrary.shared.createAutomatically(for: items)
        return items
    }

    private func loadMedia(_ urls: [URL]) async -> MediaImporter.Result {
        isImporting = true
        defer { isImporting = false }
        let result = await MediaImporter.load(urls)
        if !result.failures.isEmpty {
            alert = EditorAlert(
                title: result.items.isEmpty ? "Couldn’t import media" : "Some files couldn’t be imported",
                message: result.failures.joined(separator: "\n")
            )
        }
        return result
    }

    /// A "new track" target only creates one track; following files reuse it.
    private static func resolved(_ target: TimelineEditing.TrackTarget, after created: [UUID],
                                 in state: ProjectState) -> TimelineEditing.TrackTarget {
        guard case .newTrack(let kind) = target else { return target }
        let used = created.compactMap { state.trackIndex(ofClip: $0) }.filter { state.tracks[$0].kind == kind }
        return used.first.map { .track($0) } ?? target
    }

    private static func existingOrAppend(_ item: MediaItem, in state: inout ProjectState) -> MediaItem {
        if let existing = state.media.first(where: { $0.path == item.path }) { return existing }
        state.media.append(item)
        return item
    }
}

struct EditorAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ClipDialog: Identifiable {
    enum Kind { case speed, duration }
    let id = UUID()
    let kind: Kind
    /// Clips the dialog applies to.
    let clipIDs: Set<UUID>
    /// Clip whose current value pre-fills the dialog.
    let clipID: UUID
}

struct ZoomAnchor: Equatable {
    /// Timeline time that should stay under the anchor.
    var time: Time
    /// Anchor position relative to the visible left edge.
    var viewportX: CGFloat
}

struct DropPreview: Equatable {
    var target: TimelineEditing.TrackTarget
    /// Track that will receive the sound (or picture) of a video-with-sound file.
    var pairedTrackIndex: Int?
    var time: Time
    /// Known only for drags from the media bin.
    var duration: Time?
    var isLocked = false
}

/// Drag payload for media dragged out of the bin.
nonisolated struct MediaReference: Codable, Transferable {
    let mediaID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cutlineMediaReference)
    }
}

extension FocusedValues {
    @Entry var editor: EditorController?
}
