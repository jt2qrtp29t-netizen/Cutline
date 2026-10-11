import Foundation

/// Captions as SubRip (.srt) text, the subtitle format YouTube and players read.
nonisolated enum SubtitleFile {
    /// The captions overlapping `range`, timed from the range's start (as in the exported movie).
    static func srt(_ captions: [Caption], range: TimeRange? = nil, uppercase: Bool = false) -> String {
        let offset = range?.start ?? .zero
        var lines: [String] = []
        var number = 0
        for caption in captions {
            let start = max(caption.start, range?.start ?? caption.start), end = min(caption.end, range?.end ?? caption.end)
            guard end > start else { continue }
            number += 1
            lines.append("\(number)")
            lines.append("\(stamp(start - offset)) --> \(stamp(end - offset))")
            lines.append(uppercase ? caption.text.uppercased() : caption.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// HH:MM:SS,mmm.
    static func stamp(_ time: Time) -> String {
        let ms = max(Int((time.seconds * 1000).rounded()), 0)
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// One file per shown caption track with captions in `range`, named after the movie
    /// (the first track plain, later ones with their track name): movie.srt, movie.CC2.srt…
    static func files(for state: ProjectState, range: TimeRange, next movie: URL) -> [(URL, String)] {
        let base = movie.deletingPathExtension()
        var result: [(URL, String)] = []
        for index in state.trackIndices(of: .caption) where state.isTrackActive(index) {
            let captions = state.captions(onTrack: index).filter { $0.range.overlaps(range) }
            guard !captions.isEmpty else { continue }
            let name = result.isEmpty ? base.lastPathComponent : "\(base.lastPathComponent).\(state.tracks[index].name)"
            let uppercase = state.tracks[index].captions?.style.isUppercase ?? false
            result.append((base.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("srt"),
                           srt(captions, range: range, uppercase: uppercase)))
        }
        return result
    }
}
