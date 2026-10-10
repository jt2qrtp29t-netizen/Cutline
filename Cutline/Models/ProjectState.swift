import Foundation
import UniformTypeIdentifiers

/// The complete, serializable contents of a project. A plain value type, so the
/// whole state can be snapshotted cheaply for undo and saving.
nonisolated struct ProjectState: Codable, Hashable, Sendable {
    /// 2: separate audio tracks, track locking, crop and volume.
    /// 3: text clips live on their own text tracks (T1, T2, …).
    static let currentVersion = 3

    var version = ProjectState.currentVersion
    /// Identifies the project (e.g. to find its Playground). Projects made before v3.2
    /// have none and are identified by their file location instead.
    var id: UUID?
    var settings: ProjectSettings
    var media: [MediaItem] = []
    var tracks: [Track]
    var markers: [Marker] = []
    /// The last export settings used for this project.
    var exportSettings = ExportSettings()

    init(settings: ProjectSettings = .default, videoTracks: Int = 1, audioTracks: Int = 1, textTracks: Int = 1) {
        self.settings = settings
        self.tracks = (0..<videoTracks).map { Track(id: UUID(), name: "V\($0 + 1)", kind: .video) }
            + (0..<audioTracks).map { Track(id: UUID(), name: "A\($0 + 1)", kind: .audio) }
            + (0..<textTracks).map { Track(id: UUID(), name: "T\($0 + 1)", kind: .text) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        settings = try c.decode(ProjectSettings.self, forKey: .settings)
        media = try c.decodeIfPresent([MediaItem].self, forKey: .media) ?? []
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        exportSettings = try c.decodeIfPresent(ExportSettings.self, forKey: .exportSettings) ?? ExportSettings()
        if version < 2 { migrateSeparatingAudio() }
        if version < 3 { migrateTextToTextTracks() }
        version = Self.currentVersion
    }

    /// Text clips used to sit on video tracks. Move each video track's text clips to a
    /// text track of the same number, and make sure there's at least one text track.
    private mutating func migrateTextToTextTracks() {
        for (ordinal, index) in trackIndices(of: .video).enumerated() {
            let texts = tracks[index].clips.filter(\.isText)
            guard !texts.isEmpty else { continue }
            tracks[index].clips.removeAll(where: \.isText)
            var list = trackIndices(of: .text)
            while list.count <= ordinal {
                appendTrack(.text)
                list = trackIndices(of: .text)
            }
            tracks[list[ordinal]].clips += texts
            tracks[list[ordinal]].sortClips()
        }
        if trackIndices(of: .text).isEmpty { appendTrack(.text) }
    }

    /// Version 1 played embedded audio from video clips. Version 2 keeps sound on
    /// audio tracks, so each such clip gets an unlinked audio twin on a matching A track.
    private mutating func migrateSeparatingAudio() {
        let videoIndices = trackIndices(of: .video)
        for (ordinal, index) in videoIndices.enumerated() {
            for clip in tracks[index].clips where mediaItem(clip.mediaID)?.hasAudio == true {
                let audioIndex = audioTrackIndex(ordinal: ordinal)
                var twin = clip
                twin.id = UUID()
                tracks[audioIndex].clips.append(twin)
                tracks[audioIndex].sortClips()
            }
        }
        if trackIndices(of: .audio).isEmpty { appendTrack(.audio) }
    }

    // MARK: Lookup

    var duration: Time {
        tracks.flatMap(\.clips).map(\.end).max() ?? .zero
    }

    func mediaItem(_ id: UUID) -> MediaItem? {
        media.first { $0.id == id }
    }

    func clip(_ id: UUID) -> Clip? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    func location(ofClip id: UUID) -> (track: Int, index: Int)? {
        for (t, track) in tracks.enumerated() {
            if let i = track.clips.firstIndex(where: { $0.id == id }) { return (t, i) }
        }
        return nil
    }

    func trackIndex(ofClip id: UUID) -> Int? { location(ofClip: id)?.track }

    func track(ofClip id: UUID) -> Track? { trackIndex(ofClip: id).map { tracks[$0] } }

    /// Whether a track contributes to playback, taking mute and solo into account.
    /// Solo is evaluated per kind: soloing an audio track doesn't hide video.
    func isTrackActive(_ index: Int) -> Bool {
        // Views can briefly ask about a track that was just deleted.
        guard tracks.indices.contains(index) else { return false }
        let track = tracks[index]
        if track.isMuted { return false }
        let anySolo = tracks.contains { $0.kind == track.kind && $0.isSoloed }
        return !anySolo || track.isSoloed
    }

    /// Whether a clip plays: its track must be active, the clip not muted, and if any
    /// clip of the same kind is soloed, this one must be soloed too.
    func isClipActive(_ clip: Clip, onTrack index: Int) -> Bool {
        guard tracks.indices.contains(index), isTrackActive(index), !clip.isMuted else { return false }
        let kind = tracks[index].kind
        let anyClipSolo = tracks.contains { $0.kind == kind && $0.clips.contains(where: \.isSoloed) }
        return !anyClipSolo || clip.isSoloed
    }

    /// True if the clip or its track is locked.
    func isClipLocked(_ id: UUID) -> Bool {
        guard let loc = location(ofClip: id) else { return false }
        return tracks[loc.track].isLocked || tracks[loc.track].clips[loc.index].isLocked
    }

    /// The clip and every clip linked to it.
    func linkedGroup(of id: UUID) -> Set<UUID> {
        guard let linkID = clip(id)?.linkID else { return [id] }
        return Set(allClips.filter { $0.linkID == linkID }.map(\.id))
    }

    var allClips: [Clip] { tracks.flatMap(\.clips) }

    /// Indices into `tracks` for one kind, in layer order (V1 / A1 first).
    func trackIndices(of kind: TrackKind) -> [Int] {
        tracks.indices.filter { tracks[$0].kind == kind }
    }

    /// Position of a track among the tracks of its kind (V1 / A1 = 0).
    func ordinal(ofTrack index: Int) -> Int {
        guard tracks.indices.contains(index) else { return 0 }
        return trackIndices(of: tracks[index].kind).firstIndex(of: index) ?? 0
    }

    func trackIndex(withID id: UUID) -> Int? {
        tracks.firstIndex { $0.id == id }
    }

    // MARK: Mutation helpers

    mutating func updateClip(_ id: UUID, _ body: (inout Clip) -> Void) {
        guard let loc = location(ofClip: id) else { return }
        body(&tracks[loc.track].clips[loc.index])
        tracks[loc.track].sortClips()
    }

    mutating func updateMarker(_ id: UUID, _ body: (inout Marker) -> Void) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        body(&markers[i])
        markers.sort { $0.time < $1.time }
    }

    /// Adds a track with the next free name (V4, A3, …) and returns its index.
    @discardableResult
    mutating func appendTrack(_ kind: TrackKind) -> Int {
        let used = Set(tracks.map(\.name))
        var n = trackIndices(of: kind).count + 1
        while used.contains("\(kind.prefix)\(n)") { n += 1 }
        tracks.append(Track(id: UUID(), name: "\(kind.prefix)\(n)", kind: kind))
        return tracks.count - 1
    }

    /// The audio track paired with the n-th video track, created if needed.
    mutating func audioTrackIndex(ordinal: Int) -> Int {
        var audio = trackIndices(of: .audio)
        while audio.count <= ordinal {
            appendTrack(.audio)
            audio = trackIndices(of: .audio)
        }
        return audio[ordinal]
    }

    // MARK: Serialization

    static func decode(_ data: Data) throws -> ProjectState {
        try JSONDecoder().decode(ProjectState.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

nonisolated extension UTType {
    static let cutlineProject = UTType(exportedAs: "app.cutline.project")
    static let cutlineMediaReference = UTType(exportedAs: "app.cutline.media-reference")
    static let cutlineTransition = UTType(exportedAs: "app.cutline.transition")
}
