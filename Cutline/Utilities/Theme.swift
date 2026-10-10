import CoreImage
import SwiftUI

/// The single source of truth for every color and shared metric in the app.
/// Views reference these tokens; no view defines its own colors.
enum Theme {
    // MARK: Surfaces

    /// Window, panel and timeline background.
    static let background = Color(hex: 0x1A1A19)
    /// Recessed areas: preview surround, track lanes, text field wells.
    static let recessed = Color(hex: 0x121211)
    /// Raised surfaces, controls and borders.
    static let raised = Color(hex: 0x242423)
    /// Hover state for raised surfaces.
    static let raisedHover = Color(hex: 0x2E2E2C)
    /// Hairline borders between panels.
    static let border = Color(hex: 0x242423)
    /// The video canvas behind the composition (letterbox area inside the preview).
    static let canvas = Color(hex: 0x000000)

    // MARK: Text

    static let textPrimary = Color(hex: 0xECECE9)
    static let textSecondary = Color(hex: 0x9E9E99)
    static let textTertiary = Color(hex: 0x666662)
    /// Text drawn on top of the accent color.
    static let textOnAccent = Color(hex: 0x0B1F12)

    // MARK: Accent / playhead

    static let accent = Color(hex: 0x3BD473)
    static let accentMuted = Color(hex: 0x3BD473).opacity(0.18)
    static let playhead = Color(hex: 0x3BD473)
    static let playheadOutline = Color(hex: 0x000000)
    static let playheadGlow = Color(hex: 0x3BD473).opacity(0.45)
    static let destructive = Color(hex: 0xE5484D)

    // MARK: Clips

    static let clipFill = Color(hex: 0x3175A8)
    static let clipBorder = Color(hex: 0x285F88)
    static let clipBorderSelected = Color(hex: 0x4F93C8)
    /// Transition markers drawn over cuts on the timeline.
    static let transitionFill = Color(hex: 0x1B1B1A).opacity(0.78)
    static let transitionBorder = Color(hex: 0xC9A2F2)
    static let transitionBorderSelected = Color(hex: 0xE6D2FF)
    static let transitionDropTarget = Color(hex: 0xC9A2F2).opacity(0.35)
    static let clipLabelStrip = Color(hex: 0x25597F)
    static let clipText = Color(hex: 0xF2F6FA)
    static let clipOffline = Color(hex: 0x6B2E30)
    static let offlineBadge = Color(hex: 0xE5484D)
    /// The viewer's "Media Offline" slate (drawn by the compositor, off the main actor).
    nonisolated static let offlineSlateFill = CIColor(red: 0x8A / 255, green: 0x1F / 255, blue: 0x24 / 255)
    /// Translucent preview of where a dragged clip will land.
    static let clipGhost = Color(hex: 0x3175A8).opacity(0.45)

    // MARK: Audio clips

    static let audioClipFill = Color(hex: 0x2A7F6E)
    static let audioClipBorder = Color(hex: 0x226A5C)
    static let audioClipBorderSelected = Color(hex: 0x52B8A3)
    static let audioClipLabelStrip = Color(hex: 0x1E5C50)
    static let waveform = Color(hex: 0xA8E6D8)
    static let audioClipGhost = Color(hex: 0x2A7F6E).opacity(0.45)

    // MARK: Track states

    static let mutedTrack = Color(hex: 0xE5A43B)
    static let soloTrack = Color(hex: 0xF2C94C)

    // MARK: Text clips

    static let textClipFill = Color(hex: 0x6E54B5)
    static let textClipBorder = Color(hex: 0x5A4496)
    static let textClipBorderSelected = Color(hex: 0x9C84E0)
    static let textClipLabelStrip = Color(hex: 0x4F3B86)
    static let textClipGhost = Color(hex: 0x6E54B5).opacity(0.45)

    // MARK: Keyframes

    static let keyframe = Color(hex: 0xE8C547)
    static let keyframeSelected = Color(hex: 0xFFFFFF)
    static let curve = Color(hex: 0x3BD473)
    static let curveHandle = Color(hex: 0x6FB7F0)
    static let curveGrid = Color(hex: 0x2A2A28)

    // MARK: Locking

    /// Diagonal hatching drawn over locked lanes.
    static let lockedHatch = Color(hex: 0x000000).opacity(0.28)
    static let lockedClipDim = Color(hex: 0x121211).opacity(0.45)

    // MARK: Timeline

    static let rulerTickMajor = Color(hex: 0x6E6E69)
    static let rulerTickMinor = Color(hex: 0x3A3A38)
    static let rulerText = Color(hex: 0x8E8E89)
    static let laneSeparator = Color(hex: 0x1A1A19)
    static let snapGuide = Color(hex: 0xF2C94C)
    static let dropTarget = Color(hex: 0x3BD473).opacity(0.10)

    // MARK: Shadows

    static let shadow = Color(hex: 0x000000).opacity(0.35)

    // MARK: Metrics

    enum Metrics {
        static let panelCornerRadius: CGFloat = 10
        static let clipCornerRadius: CGFloat = 6
        static let controlCornerRadius: CGFloat = 6
        static let rulerHeight: CGFloat = 30
        static let laneHeight: CGFloat = 64
        static let audioLaneHeight: CGFloat = 48
        static let textLaneHeight: CGFloat = 40
        static let titleBarHeight: CGFloat = 40
        /// Room for the window's close / minimize / zoom buttons.
        static let trafficLightInset: CGFloat = 78
        static let laneSpacing: CGFloat = 2
        static let trackHeaderWidth: CGFloat = 124
        static let clipLabelHeight: CGFloat = 16
        static let trimHandleWidth: CGFloat = 7
        static let snapThreshold: CGFloat = 8
        static let inspectorWidth: CGFloat = 310
        static let mediaBinWidth: CGFloat = 270
    }
}

extension Theme {
    /// Marker palette. Independent of the accent and clip colors.
    static func marker(_ color: MarkerColor) -> Color {
        switch color {
        case .red: Color(hex: 0xE5484D)
        case .orange: Color(hex: 0xF0883E)
        case .yellow: Color(hex: 0xF2C94C)
        case .green: Color(hex: 0x8BC34A)
        case .cyan: Color(hex: 0x3EC6D6)
        case .blue: Color(hex: 0x5B8DEF)
        case .purple: Color(hex: 0xA672E8)
        case .pink: Color(hex: 0xE86FB0)
        }
    }
}

extension Color {
    /// Builds an sRGB color from a 0xRRGGBB literal. Only Theme should call this.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
