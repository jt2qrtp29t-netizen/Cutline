import Foundation

/// Predicts how long an export takes on this Mac. Drawing frames and encoding them
/// overlap, so an export runs at about the speed of the slower of the two. Both start
/// from speeds measured on Apple silicon, and each encoder's prediction is corrected by
/// how long past exports with it actually took.
nonisolated enum ExportTimeEstimate {
    /// The encoder an export uses, which sets most of its speed.
    enum Encoder: String, CaseIterable, Sendable {
        case hevc, hevcFast, h264, proRes, hevcSoftware, h264Software

        init(_ settings: ExportSettings) {
            switch settings.codec {
            case .proRes422: self = .proRes
            case .h264: self = settings.hardwareEncoding ? .h264 : .h264Software
            case .hevc: self = !settings.hardwareEncoding ? .hevcSoftware : settings.usesFastEncoding ? .hevcFast : .hevc
            }
        }

        /// Megapixels encoded per second (measured on an M4 with detailed 4K and 1080p footage).
        var megapixelsPerSecond: Double {
            switch self {
            case .hevc: 460
            case .hevcFast: 860
            case .h264: 480
            case .proRes: 2_000
            case .hevcSoftware: 26
            case .h264Software: 220
            }
        }
    }

    /// Megapixels drawn per second for a frame of complexity 1 (one plain layer).
    static let renderMegapixelsPerSecond = 4_500.0
    /// Setup, the audio mix and finishing the file.
    static let overheadSeconds = 0.5

    /// How much work drawing an average frame of `range` is, relative to one plain layer:
    /// each visible layer adds to it, more so when graded or running Labs effects.
    static func complexity(of state: ProjectState, in range: TimeRange) -> Double {
        let length = range.duration.seconds
        guard length > 0 else { return 1 }
        var cost = 1.0
        for index in state.trackIndices(of: .video) + state.trackIndices(of: .text) {
            for clip in state.tracks[index].clips {
                let overlap = (min(clip.end, range.end) - max(clip.start, range.start)).seconds
                guard overlap > 0 else { continue }
                var layer = 0.3
                if !clip.color.isNeutral || clip.animation.keyframes.keys.contains(where: \.isColor) { layer += 0.8 }
                layer += 0.8 * Double(clip.labs.filter(\.isEnabled).count + (clip.generator == nil ? 0 : 1))
                cost += layer * overlap / length
            }
        }
        return cost
    }

    /// The uncorrected prediction, in seconds. Frames are drawn at the project's size
    /// (`project`) and encoded at the export's (`width` × `height`).
    static func predicted(frames: Int, width: Int, height: Int, project: ProjectSettings,
                          encoder: Encoder, complexity: Double) -> Double {
        let encode = Double(width * height) / 1_000_000 / encoder.megapixelsPerSecond
        let render = Double(project.width * project.height) / 1_000_000 * complexity / renderMegapixelsPerSecond
        // Mostly overlapped: the slower stage sets the pace, the other adds a little.
        let perFrame = max(encode, render) + 0.1 * min(encode, render)
        return overheadSeconds + Double(frames) * perFrame
    }

    /// The prediction corrected by this Mac's past exports with the same encoder.
    static func seconds(frames: Int, width: Int, height: Int, project: ProjectSettings,
                        settings: ExportSettings, complexity: Double) -> Double {
        let encoder = Encoder(settings)
        return predicted(frames: frames, width: width, height: height, project: project, encoder: encoder, complexity: complexity)
            * correction(for: encoder)
    }

    // MARK: Learning

    static let correctionRange = 0.25...4.0

    static func correction(for encoder: Encoder, defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.double(forKey: key(encoder))
        return stored > 0 ? stored.clamped(to: correctionRange) : 1
    }

    /// Folds a finished export into the correction for its encoder. Very short exports
    /// are mostly overhead, so they're ignored.
    static func learn(encoder: Encoder, predicted: Double, actual: Double, defaults: UserDefaults = .standard) {
        guard predicted > 0, actual >= 2 else { return }
        let ratio = (actual / predicted).clamped(to: correctionRange)
        let previous = defaults.double(forKey: key(encoder))
        let blended = previous > 0 ? previous * 0.5 + ratio * 0.5 : ratio
        defaults.set(blended.clamped(to: correctionRange), forKey: key(encoder))
    }

    static func resetLearning(defaults: UserDefaults = .standard) {
        Encoder.allCases.forEach { defaults.removeObject(forKey: key($0)) }
    }

    private static func key(_ encoder: Encoder) -> String { "export.speedCorrection.\(encoder.rawValue)" }
}
