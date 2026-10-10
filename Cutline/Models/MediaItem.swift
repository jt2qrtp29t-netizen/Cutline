import Foundation

/// A reference to an imported video or audio file. The file itself is never modified.
nonisolated struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Absolute path at import time; used when the bookmark cannot be resolved.
    var path: String
    var bookmark: Data?
    var duration: Time
    /// Display size after applying the track's preferred transform (0 for audio-only files).
    var width: Int
    var height: Int
    var frameRate: Double
    var hasVideo = true
    var hasAudio: Bool

    init(id: UUID, name: String, path: String, bookmark: Data? = nil, duration: Time,
         width: Int, height: Int, frameRate: Double, hasVideo: Bool = true, hasAudio: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        duration = try c.decode(Time.self, forKey: .duration)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        frameRate = try c.decode(Double.self, forKey: .frameRate)
        hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? true
        hasAudio = try c.decode(Bool.self, forKey: .hasAudio)
    }

    var fileURL: URL { URL(fileURLWithPath: path) }
    var isAudioOnly: Bool { !hasVideo }

    /// Resolves the file location, preferring the bookmark so moved files are still found.
    func resolveURL() -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return fileURL
    }
}
