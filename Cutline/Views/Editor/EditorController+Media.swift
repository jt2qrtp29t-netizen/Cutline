import AppKit
import UniformTypeIdentifiers

// MARK: Offline media

extension EditorController {
    /// Media used by clips on the timeline whose files are missing.
    var offlineMedia: [MediaItem] {
        let used = Set(state.allClips.filter { !$0.isText }.map(\.mediaID))
        return MediaURLCache.shared.offline(state.media.filter { used.contains($0.id) })
    }

    func isOffline(_ media: MediaItem) -> Bool { !MediaURLCache.shared.isAvailable(media) }

    /// Asks for the new location of a missing file. Other missing files with the same
    /// names in the chosen folder are relinked too.
    func relinkMedia(_ id: UUID) {
        guard let media = state.mediaItem(id) else { return }
        let panel = NSOpenPanel()
        panel.title = "Locate “\(media.name)”"
        panel.message = "Choose the file to use for “\((media.path as NSString).lastPathComponent)”."
        panel.prompt = "Relink"
        panel.allowedContentTypes = [.audiovisualContent]
        panel.directoryURL = existingFolder(near: URL(fileURLWithPath: media.path))
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var replacements = [id: url]
        // Siblings: other offline media whose file name is in the same folder.
        let folder = url.deletingLastPathComponent()
        for other in offlineMedia where other.id != id {
            let candidate = folder.appendingPathComponent((other.path as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: candidate.path) { replacements[other.id] = candidate }
        }
        Task { await relink(replacements) }
    }

    /// Points media items at new files, after checking each file has what the item needs.
    func relink(_ replacements: [UUID: URL]) async {
        var updated: [MediaItem] = []
        var problems: [String] = []
        for (id, url) in replacements {
            guard let media = state.mediaItem(id) else { continue }
            do {
                let probed = try await MediaImporter.makeItem(for: url)
                if media.hasVideo && !probed.hasVideo {
                    problems.append("“\(url.lastPathComponent)” has no video, but “\(media.name)” is a video.")
                    continue
                }
                var relinked = media
                relinked.path = probed.path
                relinked.bookmark = probed.bookmark
                relinked.duration = probed.duration
                relinked.width = probed.width
                relinked.height = probed.height
                relinked.frameRate = probed.frameRate
                relinked.hasVideo = probed.hasVideo
                relinked.hasAudio = probed.hasAudio
                updated.append(relinked)
            } catch {
                problems.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        if !updated.isEmpty {
            store.edit(updated.count == 1 ? "Relink Media" : "Relink \(updated.count) Media Files") { state in
                for item in updated {
                    if let index = state.media.firstIndex(where: { $0.id == item.id }) { state.media[index] = item }
                }
            }
            MediaURLCache.shared.recheck()
        }
        if !problems.isEmpty {
            alert = EditorAlert(title: "Couldn’t relink", message: problems.joined(separator: "\n"))
        }
    }

    /// The nearest folder of `url` that still exists, to start the open panel in.
    private func existingFolder(near url: URL) -> URL? {
        var folder = url.deletingLastPathComponent()
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.path) { return folder }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }
}
