import Foundation

/// An sRGB color with alpha, stored as 0…1 components.
nonisolated struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
}

nonisolated enum StrokePosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case inside, center, outside

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Content and look of a text clip. Position, zoom, rotation and opacity come from
/// the clip's transform like any other video clip.
nonisolated struct TextStyle: Codable, Hashable, Sendable {
    static let maximumLength = 200

    var string = "Text"
    /// PostScript name of the font face, e.g. "Helvetica-Bold".
    var fontName = "Helvetica-Bold"
    /// Font size in project pixels.
    var size: Double = 120
    var color: RGBAColor = .white
    var strokeEnabled = false
    var strokePosition: StrokePosition = .outside
    /// Stroke width in project pixels.
    var strokeWidth: Double = 6
    var strokeColor: RGBAColor = .black

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TextStyle()
        string = try c.decodeIfPresent(String.self, forKey: .string) ?? defaults.string
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? defaults.fontName
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? defaults.size
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color) ?? defaults.color
        strokeEnabled = try c.decodeIfPresent(Bool.self, forKey: .strokeEnabled) ?? defaults.strokeEnabled
        strokePosition = try c.decodeIfPresent(StrokePosition.self, forKey: .strokePosition) ?? defaults.strokePosition
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? defaults.strokeWidth
        strokeColor = try c.decodeIfPresent(RGBAColor.self, forKey: .strokeColor) ?? defaults.strokeColor
    }
}
