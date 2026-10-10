import CoreGraphics

nonisolated enum ResolutionPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case hd1080 = "1080p"
    case uhd4K = "4K"
    case custom = "Custom"

    var id: String { rawValue }

    var size: (width: Int, height: Int)? {
        switch self {
        case .hd1080: (1920, 1080)
        case .uhd4K: (3840, 2160)
        case .custom: nil
        }
    }
}

nonisolated struct ProjectSettings: Codable, Hashable, Sendable {
    static let supportedFrameRates = [24, 25, 30, 60]

    var name: String
    var width: Int
    var height: Int
    var frameRate: Int

    var renderSize: CGSize { CGSize(width: width, height: height) }
    var aspectRatio: CGFloat { CGFloat(width) / CGFloat(max(height, 1)) }
    var frameDuration: Time { Time.frame(fps: frameRate) }

    static let `default` = ProjectSettings(name: "Untitled", width: 1920, height: 1080, frameRate: 30)

    var resolutionLabel: String {
        let preset = ResolutionPreset.allCases.first { $0.size?.width == width && $0.size?.height == height }
        return preset.map { "\($0.rawValue) · \(width)×\(height)" } ?? "\(width)×\(height)"
    }
}
