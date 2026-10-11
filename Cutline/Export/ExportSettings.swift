import Foundation

nonisolated enum ExportCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264, hevc, proRes422

    var id: String { rawValue }
    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        case .proRes422: "Apple ProRes 422"
        }
    }
    /// ProRes has a fixed quality; the others use a bitrate.
    var usesBitrate: Bool { self != .proRes422 }
}

nonisolated enum ExportContainer: String, Codable, CaseIterable, Identifiable, Sendable {
    case mp4, mov
    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String { self == .mp4 ? "MPEG-4 (.mp4)" : "QuickTime (.mov)" }
}

/// Output frame size.
nonisolated enum ExportResolution: Codable, Hashable, Sendable {
    case project
    case p1080
    case p1440
    case p2160
    /// 1080 × 1920.
    case vertical
    /// 1080 × 1080.
    case square
    case custom(width: Int, height: Int)

    static let choices: [ExportResolution] = [.project, .p1080, .p1440, .p2160, .vertical, .square]

    var title: String {
        switch self {
        case .project: "Project Size"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        case .vertical: "Vertical 1080 × 1920"
        case .square: "Square 1080 × 1080"
        case let .custom(width, height): "Custom \(width) × \(height)"
        }
    }

    /// The pixel size for a project. Landscape sizes keep the project's aspect ratio
    /// (by height), rounded to even numbers as encoders require.
    func size(for project: ProjectSettings) -> (width: Int, height: Int) {
        func byHeight(_ height: Int) -> (Int, Int) {
            let width = Double(height) * Double(project.width) / Double(max(project.height, 1))
            return (Self.even(Int(width.rounded())), height)
        }
        switch self {
        case .project: return (Self.even(project.width), Self.even(project.height))
        case .p1080: return byHeight(1080)
        case .p1440: return byHeight(1440)
        case .p2160: return byHeight(2160)
        case .vertical: return (1080, 1920)
        case .square: return (1080, 1080)
        case let .custom(width, height): return (Self.even(max(width, 16)), Self.even(max(height, 16)))
        }
    }

    private static func even(_ value: Int) -> Int { value + value % 2 }
}

/// How the picture fills an output with a different shape.
nonisolated enum ExportFit: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Center crop: fills the frame, cutting off the sides (or top and bottom).
    case fill
    /// Fit inside the frame with black bars.
    case fit
    var id: String { rawValue }
    var title: String { self == .fill ? "Crop to Fill" : "Fit (Letterbox)" }
}

/// What part of the timeline to export.
nonisolated enum ExportRangeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, inOut, selection
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Whole Timeline"
        case .inOut: "In to Out"
        case .selection: "Selected Clips"
        }
    }
}

/// Everything about how a timeline is exported. Saved with the project.
nonisolated struct ExportSettings: Codable, Hashable, Sendable {
    var presetID = ExportPreset.youTube1080.id
    var resolution = ExportResolution.project
    var fit = ExportFit.fill
    /// Nil = the project's frame rate.
    var frameRate: Int?
    var codec = ExportCodec.h264
    var container = ExportContainer.mp4
    /// 0...1: from small files to high quality (sets the bitrate for H.264 and HEVC).
    var quality = 0.6
    var hardwareEncoding = true
    /// HEVC only: the hardware encoder's faster mode, with the bitrate raised to keep
    /// the same quality (measured: about 1.9× faster for files about 20% larger).
    var fastEncoding = true
    /// Puts the movie's index at the start of the file, so it can start playing while
    /// it downloads (web, YouTube and social uploads).
    var networkOptimized = true
    /// Audio: AAC.
    var audioBitrate = 192
    var audioSampleRate = 48_000
    var audioChannels = 2

    var range = ExportRangeKind.all
    var inPoint: Time?
    var outPoint: Time?

    /// Name without extension; nil = based on the project's name.
    var fileName: String?
    /// The folder last exported to.
    var folderPath: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? d.presetID
        resolution = try c.decodeIfPresent(ExportResolution.self, forKey: .resolution) ?? d.resolution
        fit = try c.decodeIfPresent(ExportFit.self, forKey: .fit) ?? d.fit
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate)
        codec = try c.decodeIfPresent(ExportCodec.self, forKey: .codec) ?? d.codec
        container = try c.decodeIfPresent(ExportContainer.self, forKey: .container) ?? d.container
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? d.quality
        hardwareEncoding = try c.decodeIfPresent(Bool.self, forKey: .hardwareEncoding) ?? d.hardwareEncoding
        fastEncoding = try c.decodeIfPresent(Bool.self, forKey: .fastEncoding) ?? d.fastEncoding
        networkOptimized = try c.decodeIfPresent(Bool.self, forKey: .networkOptimized) ?? d.networkOptimized
        audioBitrate = try c.decodeIfPresent(Int.self, forKey: .audioBitrate) ?? d.audioBitrate
        audioSampleRate = try c.decodeIfPresent(Int.self, forKey: .audioSampleRate) ?? d.audioSampleRate
        audioChannels = try c.decodeIfPresent(Int.self, forKey: .audioChannels) ?? d.audioChannels
        range = try c.decodeIfPresent(ExportRangeKind.self, forKey: .range) ?? d.range
        inPoint = try c.decodeIfPresent(Time.self, forKey: .inPoint)
        outPoint = try c.decodeIfPresent(Time.self, forKey: .outPoint)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
    }

    static let audioBitrates = [96, 128, 192, 256, 320]
    static let audioSampleRates = [44_100, 48_000]

    /// ProRes only goes in QuickTime files.
    var effectiveContainer: ExportContainer { codec == .proRes422 ? .mov : container }

    func frameRate(for project: ProjectSettings) -> Int { frameRate ?? project.frameRate }

    /// Whether the faster hardware HEVC mode is in use.
    var usesFastEncoding: Bool { codec == .hevc && hardwareEncoding && fastEncoding }
    /// The extra bitrate that gives the faster mode the same quality as the normal one.
    static let fastEncodingBitrateFactor = 1.2

    /// Video bitrate in bits per second (estimated for ProRes).
    func videoBitrate(for project: ProjectSettings) -> Double {
        let (w, h) = resolution.size(for: project)
        let pixelsPerSecond = Double(w * h * frameRate(for: project))
        switch codec {
        // ProRes 422: about 147 Mbit/s at 1080p30, scaling with pixels per second.
        case .proRes422: return 147_000_000 * pixelsPerSecond / (1920 * 1080 * 30)
        // Bits per pixel from small to high quality; HEVC needs about 60% of H.264.
        case .h264: return pixelsPerSecond * (0.03 + quality * 0.22)
        case .hevc: return pixelsPerSecond * (0.03 + quality * 0.22) * 0.6
            * (usesFastEncoding ? Self.fastEncodingBitrateFactor : 1)
        }
    }

    /// Estimated file size in bytes for `seconds` of video.
    func estimatedBytes(seconds: Double, project: ProjectSettings) -> Double {
        (videoBitrate(for: project) + Double(audioBitrate * 1000)) * seconds / 8
    }

    /// The timeline range to export, or nil if that range is empty or not set.
    func timeRange(timelineDuration: Time, selection: [Clip]) -> TimeRange? {
        let whole = TimeRange(start: .zero, end: timelineDuration)
        let range: TimeRange
        switch self.range {
        case .all:
            range = whole
        case .inOut:
            let start = inPoint ?? .zero
            let end = outPoint ?? timelineDuration
            range = TimeRange(start: max(start, .zero), end: min(end, timelineDuration))
        case .selection:
            guard let first = selection.map(\.start).min(), let last = selection.map(\.end).max() else { return nil }
            range = TimeRange(start: first, end: min(last, timelineDuration))
        }
        return range.duration > .zero ? range : nil
    }
}

/// A named starting point for export settings. To add one, add a `static let` and
/// list it in `all`.
nonisolated struct ExportPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let symbolName: String
    /// Turns any settings into this preset's (keeping range, file name and folder).
    let apply: @Sendable (inout ExportSettings) -> Void

    static let youTube4K = ExportPreset(id: "youtube4k", name: "YouTube 4K 60", summary: "3840 × 2160 at 60 fps, HEVC, high quality.",
                                        symbolName: "play.rectangle.fill") { s in
        s.resolution = .p2160; s.fit = .fill; s.frameRate = 60; s.codec = .hevc; s.container = .mp4
        s.quality = 0.75; s.audioBitrate = 256; s.audioSampleRate = 48_000; s.audioChannels = 2
    }
    static let youTube1080 = ExportPreset(id: "youtube1080", name: "YouTube 1080p 60", summary: "1920 × 1080 at 60 fps, H.264.",
                                          symbolName: "play.rectangle") { s in
        s.resolution = .p1080; s.fit = .fill; s.frameRate = 60; s.codec = .h264; s.container = .mp4
        s.quality = 0.65; s.audioBitrate = 192; s.audioSampleRate = 48_000; s.audioChannels = 2
    }
    static let vertical = ExportPreset(id: "vertical", name: "Social Vertical", summary: "1080 × 1920 for Shorts, Reels and TikTok.",
                                       symbolName: "iphone") { s in
        s.resolution = .vertical; s.frameRate = nil; s.codec = .h264; s.container = .mp4
        s.quality = 0.6; s.audioBitrate = 192; s.audioSampleRate = 48_000; s.audioChannels = 2
    }
    static let square = ExportPreset(id: "square", name: "Social Square", summary: "1080 × 1080 for feeds.",
                                     symbolName: "square") { s in
        s.resolution = .square; s.frameRate = nil; s.codec = .h264; s.container = .mp4
        s.quality = 0.6; s.audioBitrate = 192; s.audioSampleRate = 48_000; s.audioChannels = 2
    }
    static let quickPreview = ExportPreset(id: "quick", name: "Quick Preview", summary: "Small and fast, for checking a cut.",
                                           symbolName: "hare") { s in
        s.resolution = .custom(width: 960, height: 540); s.fit = .fit; s.frameRate = nil; s.codec = .h264; s.container = .mp4
        s.quality = 0.15; s.hardwareEncoding = true; s.audioBitrate = 96; s.audioSampleRate = 44_100; s.audioChannels = 2
    }
    static let proRes = ExportPreset(id: "prores", name: "ProRes Master", summary: "Apple ProRes 422 at project size, for archiving or further editing.",
                                     symbolName: "film") { s in
        s.resolution = .project; s.fit = .fill; s.frameRate = nil; s.codec = .proRes422; s.container = .mov
        s.audioBitrate = 320; s.audioSampleRate = 48_000; s.audioChannels = 2
    }
    static let custom = ExportPreset(id: "custom", name: "Custom", summary: "Your own settings.",
                                     symbolName: "slider.horizontal.3") { _ in }

    static let all: [ExportPreset] = [youTube4K, youTube1080, vertical, square, quickPreview, proRes, custom]

    static func preset(_ id: String) -> ExportPreset? { all.first { $0.id == id } }

    /// Settings with this preset applied.
    func applied(to settings: ExportSettings) -> ExportSettings {
        var copy = settings
        apply(&copy)
        copy.presetID = id
        return copy
    }
}
