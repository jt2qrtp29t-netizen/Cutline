import Foundation

/// One spoken word, timed in its media's own (source) time, so it stays right however
/// the clips that use the media are cut, moved or retimed.
nonisolated struct TranscriptWord: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    /// The word as shown (recognized, or as edited), with any punctuation that follows it.
    var text: String
    /// Source seconds.
    var start: Double
    var end: Double
    /// How sure recognition was (0…1), if it said.
    var confidence: Double?
    /// Left out of the captions (the transcript still shows it, struck through).
    var isHidden = false
    /// A new caption starts at this word, whatever the grouping would do.
    var startsCaption = false
    /// This word stays in the same caption as the one before it (merged captions).
    var keepsWithPrevious = false

    init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        startsCaption = try c.decodeIfPresent(Bool.self, forKey: .startsCaption) ?? false
        keepsWithPrevious = try c.decodeIfPresent(Bool.self, forKey: .keepsWithPrevious) ?? false
    }
}

/// What was said in one media item, word by word.
nonisolated struct Transcript: Codable, Hashable, Sendable {
    var mediaID: UUID
    /// The language it was recognized in (a locale identifier such as "en_US").
    var locale: String
    var words: [TranscriptWord]

    /// Words whose span overlaps source seconds `range`, in order.
    func words(in range: ClosedRange<Double>) -> [TranscriptWord] {
        words.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
    }

    /// The plain text (shown words, separated by spaces).
    var text: String { words.filter { !$0.isHidden }.map(\.text).joined(separator: " ") }
}

nonisolated extension ProjectState {
    /// Media items used by clips on audio tracks (what Transcribe works on).
    var transcribableMedia: [MediaItem] {
        let used = Set(trackIndices(of: .audio).flatMap { tracks[$0].clips.map(\.mediaID) })
        return media.filter { used.contains($0.id) && $0.hasAudio }
    }
}
