import AVFoundation
import UniformTypeIdentifiers

/// Reads metadata from video files to create `MediaItem`s.
nonisolated enum MediaImporter {
    struct Result: Sendable {
        var items: [MediaItem] = []
        var failures: [String] = []
    }

    enum ImportError: LocalizedError {
        case noPlayableTracks

        var errorDescription: String? {
            switch self {
            case .noPlayableTracks: "The file has no video or audio that macOS can play."
            }
        }
    }

    /// Content types offered in the import panel. Anything AVFoundation can decode is
    /// accepted: QuickTime, MPEG-4, M4V, MP3, AAC/M4A, WAV, AIFF, CAF, FLAC, ALAC, AC-3…
    static let importableTypes: [UTType] = [.movie, .video, .audio, .audiovisualContent]

    /// Expands folders and keeps files that look like movies.
    static func candidateFiles(from urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let child = enumerator?.nextObject() as? URL {
                    if isMovie(child) { files.append(child) }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }

    static func isMovie(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) ?? false
    }

    static func load(_ urls: [URL]) async -> Result {
        var result = Result()
        for url in candidateFiles(from: urls) {
            do {
                result.items.append(try await makeItem(for: url))
            } catch {
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func makeItem(for url: URL) async throws -> MediaItem {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        guard video != nil || hasAudio, duration.seconds > 0 else {
            throw ImportError.noPlayableTracks
        }

        var width = 0, height = 0
        var frameRate: Float = 0
        if let video {
            let (naturalSize, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let displaySize = naturalSize.applying(transform)
            width = Int(abs(displaySize.width).rounded())
            height = Int(abs(displaySize.height).rounded())
            frameRate = rate
        }
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

        return MediaItem(
            id: UUID(),
            name: url.deletingPathExtension().lastPathComponent,
            path: url.path,
            bookmark: bookmark,
            duration: Time(duration),
            width: width,
            height: height,
            frameRate: Double(frameRate),
            hasVideo: video != nil,
            hasAudio: hasAudio
        )
    }
}
