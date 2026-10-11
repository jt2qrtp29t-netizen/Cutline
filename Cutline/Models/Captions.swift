import Foundation

/// How a caption track looks. One style for the whole track (stage 4 adds presets and
/// the burned-in renderer); sizes are in project pixels at 1080p and scale with the frame.
nonisolated struct CaptionStyle: Codable, Hashable, Sendable {
    var fontName = "Helvetica-Bold"
    var size: Double = 64
    var color: RGBAColor = .white
    /// The word being spoken, when highlighting is on.
    var highlightColor = RGBAColor(red: 1, green: 0.82, blue: 0.2, alpha: 1)
    var highlightsWord = false
    var strokeWidth: Double = 6
    var strokeColor: RGBAColor = .black
    var showsBox = false
    var boxColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6)
    var isUppercase = false
    /// Vertical position of the caption's center, 0 (top) … 1 (bottom).
    var position: Double = 0.82

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionStyle()
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? d.fontName
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color) ?? d.color
        highlightColor = try c.decodeIfPresent(RGBAColor.self, forKey: .highlightColor) ?? d.highlightColor
        highlightsWord = try c.decodeIfPresent(Bool.self, forKey: .highlightsWord) ?? d.highlightsWord
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? d.strokeWidth
        strokeColor = try c.decodeIfPresent(RGBAColor.self, forKey: .strokeColor) ?? d.strokeColor
        showsBox = try c.decodeIfPresent(Bool.self, forKey: .showsBox) ?? d.showsBox
        boxColor = try c.decodeIfPresent(RGBAColor.self, forKey: .boxColor) ?? d.boxColor
        isUppercase = try c.decodeIfPresent(Bool.self, forKey: .isUppercase) ?? d.isUppercase
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? d.position
    }
}

/// A caption track's settings: which audio it captions, how words group into captions,
/// and how they look.
nonisolated struct CaptionSettings: Codable, Hashable, Sendable {
    /// Audio tracks captioned; empty means every audio track.
    var sourceTrackIDs: [UUID] = []
    /// At most this many words on screen at once.
    var maxWords = 6
    /// A caption ends once it would last longer than this (seconds).
    var maxDuration = 3.0
    /// A pause at least this long (seconds) starts a new caption.
    var pauseSplit = 0.6
    /// Captions stay up at least this long (seconds), if the next one isn't due yet.
    var minDuration = 0.8
    /// Captions also end at the end of a sentence.
    var splitsSentences = true
    var style = CaptionStyle()
    /// Drawn into the picture (preview and export).
    var isBurnedIn = true

    static let wordRange = 1...20
    static let durationRange = 0.5...10.0
    static let pauseRange = 0.1...3.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionSettings()
        sourceTrackIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceTrackIDs) ?? d.sourceTrackIDs
        maxWords = try c.decodeIfPresent(Int.self, forKey: .maxWords) ?? d.maxWords
        maxDuration = try c.decodeIfPresent(Double.self, forKey: .maxDuration) ?? d.maxDuration
        pauseSplit = try c.decodeIfPresent(Double.self, forKey: .pauseSplit) ?? d.pauseSplit
        minDuration = try c.decodeIfPresent(Double.self, forKey: .minDuration) ?? d.minDuration
        splitsSentences = try c.decodeIfPresent(Bool.self, forKey: .splitsSentences) ?? d.splitsSentences
        style = try c.decodeIfPresent(CaptionStyle.self, forKey: .style) ?? d.style
        isBurnedIn = try c.decodeIfPresent(Bool.self, forKey: .isBurnedIn) ?? d.isBurnedIn
    }
}

/// A transcript word placed on the timeline (through its clip's position and speed).
nonisolated struct CaptionWord: Hashable, Sendable {
    let wordID: UUID
    let mediaID: UUID
    let text: String
    let start: Time
    let end: Time
    /// The transcript asks for a new caption here.
    let startsCaption: Bool
}

/// One caption: words shown together, from `start` until `end`.
nonisolated struct Caption: Hashable, Sendable, Identifiable {
    let words: [CaptionWord]
    let start: Time
    let end: Time

    /// Stable while the words don't change.
    var id: UUID { words.first?.wordID ?? UUID() }
    var range: TimeRange { TimeRange(start: start, end: end) }
    var text: String { words.map(\.text).joined(separator: " ") }

    /// The word being spoken at `time` (for highlighting), if any.
    func word(at time: Time) -> CaptionWord? {
        words.last { $0.start <= time }
    }
}

nonisolated extension ProjectState {
    /// Transcript words of the captioned audio, placed on the timeline: each clip shows the
    /// words of its media whose middle falls inside the part of the source it plays, at
    /// the times its position and speed curve give them. Muted clips and tracks, and
    /// hidden words, are left out.
    func captionWords(for settings: CaptionSettings) -> [CaptionWord] {
        let sources = Set(settings.sourceTrackIDs)
        var result: [CaptionWord] = []
        for index in trackIndices(of: .audio) {
            let track = tracks[index]
            guard sources.isEmpty || sources.contains(track.id) else { continue }
            for clip in track.clips where isClipActive(clip, onTrack: index) {
                guard let transcript = transcripts[clip.mediaID] else { continue }
                let from = clip.sourceStart.seconds, to = clip.sourceEnd.seconds
                let remap = clip.remap
                for word in transcript.words where !word.isHidden {
                    let middle = (word.start + word.end) / 2
                    guard middle >= from, middle < to else { continue }
                    func timeline(_ source: Double) -> Time {
                        let offset = remap.offset(forSourceSeconds: min(max(source, from), to) - from)
                        return clip.start + Time(seconds: offset)
                    }
                    let start = timeline(word.start), end = timeline(word.end)
                    guard end > start else { continue }
                    result.append(CaptionWord(wordID: word.id, mediaID: clip.mediaID, text: word.text, start: start, end: end,
                                              startsCaption: word.startsCaption))
                }
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// The captions of a caption track, in order, never overlapping: words grouped by the
    /// track's settings (a new caption at a long pause, a sentence end, the word or
    /// length limit, a clip boundary between separate recordings, or where the transcript
    /// asks for one), each shown until its last word ends (held at least the minimum
    /// time when there's room before the next).
    func captions(onTrack index: Int) -> [Caption] {
        guard tracks.indices.contains(index), let settings = tracks[index].captions else { return [] }
        let words = captionWords(for: settings)
        var groups: [[CaptionWord]] = []
        var current: [CaptionWord] = []
        let pause = Time(seconds: settings.pauseSplit), longest = Time(seconds: settings.maxDuration)
        for word in words {
            if let first = current.first, let last = current.last {
                let breaks = word.startsCaption
                    || current.count >= max(settings.maxWords, 1)
                    || word.start - last.end >= pause
                    || word.end - first.start > longest
                    || (settings.splitsSentences && last.text.last.map { ".?!".contains($0) } == true)
                if breaks {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }

        var captions: [Caption] = []
        let minimum = Time(seconds: settings.minDuration)
        for (k, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            var start = first.start
            if let previous = captions.last, start < previous.end { start = previous.end }
            var end = max(last.end, start + minimum)
            if k + 1 < groups.count, let next = groups[k + 1].first { end = min(end, max(next.start, last.end)) }
            guard end > start else { continue }
            captions.append(Caption(words: group, start: start, end: end))
        }
        return captions
    }

    /// Adds a caption track (named CC1, CC2…) captioning every audio track.
    @discardableResult
    mutating func appendCaptionTrack() -> Int {
        let index = appendTrack(.caption)
        tracks[index].captions = CaptionSettings()
        return index
    }
}
