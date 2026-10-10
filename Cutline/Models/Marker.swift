import Foundation

nonisolated enum MarkerColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, pink

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

nonisolated struct Marker: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var time: Time
    var name: String
    var color: MarkerColor
}
