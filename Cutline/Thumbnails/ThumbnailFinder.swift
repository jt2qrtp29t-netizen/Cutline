import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// A frame worth considering as the video's thumbnail, with what made it stand out.
nonisolated struct ThumbnailCandidate: Sendable, Identifiable {
    let id = UUID()
    /// Seconds into the movie.
    let time: Double
    /// The frame (up to 1280×720).
    let image: CGImage
    /// Apple's aesthetics rating, −1…1 (well composed, sharp, not a screenshot or blur).
    let aesthetics: Double
    /// Vision thinks it's a "utility" image (a screenshot, a document, a blurry transition).
    let isUtility: Bool
    /// The clearest face: capture quality (0…1) weighted by its size, 0 without faces.
    let face: Double
    /// How loud the moment is, 0…1 within this movie.
    let loudness: Double
    /// Excited speech nearby ("no way", "let's go", an exclamation…).
    let isExcited: Bool
    /// The combined score the shortlist is ranked by.
    let score: Double
    let featurePrint: FeaturePrintObservation?

    /// A short reason for showing it (without an AI model).
    var reason: String {
        var parts: [String] = []
        if face > 0.25 { parts.append("a clear face") }
        if isExcited { parts.append("an excited moment") } else if loudness > 0.75 { parts.append("a loud moment") }
        if aesthetics > 0.3 { parts.append("a sharp, well-composed frame") }
        guard !parts.isEmpty else { return "A clean frame" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Finds thumbnail candidates in a movie with Apple's on-device Vision framework (no AI
/// model needed): frames sampled across it are rated for composition and sharpness,
/// faces, loudness and excited speech, then the best distinct ones are kept.
nonisolated enum ThumbnailFinder {
    /// Words and phrases that usually mark an exciting moment in commentary.
    static let excitedPhrases = ["no way", "let's go", "lets go", "oh my god", "omg", "what the", "wow", "insane", "clutch",
                                 "finally", "boss", "victory", "winner", "we did it", "yes!", "watch this", "look at"]

    /// - Parameters:
    ///   - speech: transcript words in movie seconds (for excited moments), if any.
    ///   - samples: frames looked at, evenly spread (the first and last 3% skipped: intros, fades).
    ///   - keep: how many distinct candidates to return, best first.
    static func candidates(in movie: URL, speech: [(time: Double, text: String)] = [], samples: Int = 48, keep: Int = 12,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [ThumbnailCandidate] {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { return [] }
        let loudness = try await loudnessCurve(of: asset, duration: duration)
        let excitedTimes = speech.filter { isExcited($0.text) }.map(\.time)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)

        let margin = duration * 0.03
        let span = max(duration - margin * 2, 0.001)
        var found: [ThumbnailCandidate] = []
        for k in 0..<samples {
            try Task.checkCancellation()
            let time = margin + span * (Double(k) + 0.5) / Double(samples)
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
            let aesthetics = try? await CalculateImageAestheticsScoresRequest().perform(on: image)
            let faces = (try? await DetectFaceCaptureQualityRequest().perform(on: image)) ?? []
            let print = try? await GenerateImageFeaturePrintRequest().perform(on: image)
            var face = 0.0
            for f in faces {
                let quality = Double(f.captureQuality?.score ?? 0)
                let area = Double(f.boundingBox.width) * Double(f.boundingBox.height)
                face = max(face, quality * min(1, (area * 12).squareRoot()))
            }
            let loud = loudness.isEmpty ? 0 : loudness[min(loudness.count - 1, Int(time / loudnessStep))]
            let excited = excitedTimes.contains { abs($0 - time) < 1.5 }
            let rating = Double(aesthetics?.overallScore ?? 0)
            let utility = aesthetics?.isUtility ?? false
            let look: Double = 0.5 * (rating + 1) / 2
            let bonus: Double = 0.25 * face + 0.15 * loud + (excited ? 0.1 : 0)
            let score = look + bonus - (utility ? 0.25 : 0)
            found.append(ThumbnailCandidate(time: time, image: image, aesthetics: rating, isUtility: utility, face: face,
                                            loudness: loud, isExcited: excited, score: score, featurePrint: print))
            progress(Double(k + 1) / Double(samples))
        }
        return distinct(found.sorted { $0.score > $1.score }, keep: keep, minimumGap: duration / Double(max(keep * 3, 1)))
    }

    static func isExcited(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("!") || excitedPhrases.contains { lower.contains($0) }
    }

    /// Best first, skipping frames that look like one already kept or sit right next to one.
    static func distinct(_ ranked: [ThumbnailCandidate], keep: Int, minimumGap: Double) -> [ThumbnailCandidate] {
        var kept: [ThumbnailCandidate] = []
        for candidate in ranked where kept.count < keep {
            let tooClose = kept.contains { other in
                if abs(other.time - candidate.time) < minimumGap { return true }
                guard let a = candidate.featurePrint, let b = other.featurePrint, let distance = try? a.distance(to: b) else { return false }
                return distance < similarity
            }
            if !tooClose { kept.append(candidate) }
        }
        return kept
    }

    /// Feature-print distance under which two frames count as the same shot.
    static let similarity = 0.35
    static let loudnessStep = 0.5

    /// RMS of the movie's sound every half second, as 0…1 within the movie (nothing if it has no sound).
    static func loudnessCurve(of asset: AVURLAsset, duration: Double) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        // The track's own rate and channels (interleaved float samples).
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]))
        try reader.start()
        var sums = [Double](repeating: 0, count: Int((duration / loudnessStep).rounded(.up)) + 1)
        var counts = [Int](repeating: 0, count: sums.count)
        var frame = 0
        while let sample = try await provider.next() {
            let (values, rate, channels): ([Float], Double, Int) = sample.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer),
                      let format = CMSampleBufferGetFormatDescription(buffer),
                      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return ([], 0, 1) }
                let length = CMBlockBufferGetDataLength(block)
                var floats = [Float](repeating: 0, count: length / 4)
                _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                return (floats, description.mSampleRate, max(Int(description.mChannelsPerFrame), 1))
            }
            guard rate > 0 else { continue }
            let window = Int(rate * loudnessStep)
            for (i, v) in values.enumerated() {
                let bucket = (frame + i / channels) / window
                if bucket < sums.count {
                    sums[bucket] += Double(v * v)
                    counts[bucket] += 1
                }
            }
            frame += values.count / channels
        }
        let rms = zip(sums, counts).map { $1 > 0 ? ($0 / Double($1)).squareRoot() : 0 }
        guard let top = rms.max(), top > 1e-6 else { return rms.map { _ in 0 } }
        return rms.map { $0 / top }
    }
}
