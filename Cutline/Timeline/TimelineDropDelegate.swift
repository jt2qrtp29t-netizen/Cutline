import SwiftUI
import UniformTypeIdentifiers

/// Handles media dragged from the bin and video files dragged from Finder onto the lanes.
struct TimelineDropDelegate: DropDelegate {
    let editor: EditorController
    let layout: TimelineLayout

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.cutlineMediaReference, .fileURL])
    }

    func dropEntered(info: DropInfo) {
        editor.showDropPreview(preview(for: info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let preview = preview(for: info)
        editor.showDropPreview(preview)
        return DropProposal(operation: preview.isLocked ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        editor.clearDropPreview()
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = preview(for: info)
        editor.clearDropPreview()
        defer { editor.draggedMediaID = nil }
        guard !target.isLocked else { return false }

        if info.hasItemsConforming(to: [.cutlineMediaReference]), let mediaID = editor.draggedMediaID {
            editor.placeMedia(mediaID, on: target.target, at: target.time)
            return true
        }

        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadFileURL() { urls.append(url) }
            }
            editor.importAndPlace(urls, on: target.target, at: target.time)
        }
        return true
    }

    private func preview(for info: DropInfo) -> DropPreview {
        let state = editor.state
        let isBinDrag = info.hasItemsConforming(to: [.cutlineMediaReference])
        let media = isBinDrag ? editor.draggedMediaID.flatMap { state.mediaItem($0) } : nil
        let rawTime = max(layout.time(forX: info.location.x), .zero)
        let time = editor.snappedDropTime(rawTime, duration: media?.duration, layout: layout)
        let target = layout.dropTarget(forY: info.location.y) ?? .newTrack(.video)

        // Show where the other half of a video-with-sound file will go.
        var paired: Int?
        if let media, media.hasVideo && media.hasAudio, case .track(let track) = target,
           state.tracks.indices.contains(track), state.tracks[track].kind != .text {
            let otherKind: TrackKind = state.tracks[track].kind == .video ? .audio : .video
            let list = state.trackIndices(of: otherKind)
            let ordinal = state.ordinal(ofTrack: track)
            if ordinal < list.count { paired = list[ordinal] }
        }
        // Locked tracks and text tracks don't accept media.
        var isLocked = false
        switch target {
        case .track(let track):
            isLocked = !state.tracks.indices.contains(track) || state.tracks[track].isLocked || state.tracks[track].kind == .text
        case .newTrack(let kind):
            isLocked = kind == .text
        }
        return DropPreview(target: target, pairedTrackIndex: paired, time: time,
                           duration: media?.duration, isLocked: isLocked)
    }
}

extension NSItemProvider {
    /// Loads a file URL from a Finder drag.
    nonisolated func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(for: .fileURL) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url)
            }
        }
    }
}
