import AppKit
import CoreImage
import SwiftUI

/// The single source of truth for every color and shared metric in the app.
/// Views reference these tokens; no view defines its own colors. Colors with a light
/// variant follow the window's appearance (Parameters → General → Light mode); the
/// rest, like clips, scopes and the video canvas, look the same in both.
enum Theme {
    // MARK: Surfaces

    /// Window, panel and timeline background.
    static let background = Color(dark: 0x1A1A19, light: 0xD4D4CF)
    /// Recessed areas: preview surround, track lanes, text field wells.
    static let recessed = Color(dark: 0x121211, light: 0xC6C6C1)
    /// Raised surfaces, controls and borders.
    static let raised = Color(dark: 0x242423, light: 0xDFDFDA)
    /// Hover state for raised surfaces.
    static let raisedHover = Color(dark: 0x2E2E2C, light: 0xE8E8E3)
    /// Hairline borders between panels.
    static let border = Color(dark: 0x242423, light: 0xBABAB5)
    /// The video canvas behind the composition (letterbox area inside the preview).
    static let canvas = Color(hex: 0x000000)

    // MARK: Text

    static let textPrimary = Color(dark: 0xECECE9, light: 0x1A1A18)
    static let textSecondary = Color(dark: 0x9E9E99, light: 0x46463F)
    static let textTertiary = Color(dark: 0x666662, light: 0x6A6A64)
    /// Text drawn on top of the accent color.
    static let textOnAccent = Color(dark: 0x0B1F12, light: 0xFFFFFF)

    // MARK: Accent / playhead

    static let accent = Color(dark: 0x3BD473, light: 0x1E9E50)
    static let accentMuted = Color(dark: 0x3BD473, light: 0x1E9E50).opacity(0.18)
    static let playhead = Color(dark: 0x3BD473, light: 0x1E9E50)
    static let playheadOutline = Color(dark: 0x000000, light: 0xFFFFFF)
    static let playheadGlow = Color(dark: 0x3BD473, light: 0x1E9E50).opacity(0.45)
    static let destructive = Color(hex: 0xE5484D)

    // MARK: Clips

    static let clipFill = Color(hex: 0x3175A8)
    static let clipBorder = Color(hex: 0x285F88)
    static let clipBorderSelected = Color(hex: 0x4F93C8)
    /// Transition markers drawn over cuts on the timeline.
    static let transitionFill = Color(dark: 0x1B1B1A, light: 0xDFDFDA, darkOpacity: 0.78, lightOpacity: 0.85)
    static let transitionBorder = Color(dark: 0xC9A2F2, light: 0x8A5CC9)
    static let transitionBorderSelected = Color(dark: 0xE6D2FF, light: 0x5B2FA0)
    static let transitionDropTarget = Color(dark: 0xC9A2F2, light: 0x8A5CC9).opacity(0.35)
    static let clipLabelStrip = Color(hex: 0x25597F)
    static let clipText = Color(hex: 0xF2F6FA)
    static let clipOffline = Color(hex: 0x6B2E30)
    static let offlineBadge = Color(hex: 0xE5484D)

    // MARK: Playground

    /// The Playground's sandbox cue: amber instead of the usual green.
    static let sandbox = Color(dark: 0xF2A93B, light: 0xC27C12)
    static let sandboxMuted = Color(dark: 0xF2A93B, light: 0xC27C12).opacity(0.16)

    // MARK: Color tab

    /// The hue under a wheel position (x = Cb, y = Cr), as a vectorscope shows it.
    static func wheelHue(x: Double, y: Double) -> Color {
        let shift = ColorWheel(x: x, y: y).chroma * 0.9
        return Color(.sRGB, red: 0.5 + shift.x, green: 0.5 + shift.y, blue: 0.5 + shift.z)
    }
    static let wheelCenter = Color(dark: 0x3A3A38, light: 0xBABAB5)
    static let wheelRing = Color(dark: 0x0E0E0D, light: 0x8E8E88)
    static let wheelPuck = Color(hex: 0xF4F4F0)
    static let curveMaster = Color(dark: 0xE8E8E4, light: 0x3A3A38)
    static let curveRed = Color(hex: 0xF0605A)
    static let curveGreen = Color(hex: 0x52D47A)
    static let curveBlue = Color(hex: 0x5A8FF0)
    static let toneCurveGrid = Color(dark: 0xFFFFFF, light: 0x000000, darkOpacity: 0.07, lightOpacity: 0.08)
    static let curvePlot = Color(dark: 0x121211, light: 0xC6C6C1)
    /// A hue (0...1) for the hue vs saturation strip.
    static func hueStrip(_ hue: Double) -> Color { Color(hue: hue, saturation: 0.7, brightness: 0.85) }
    static let scopeTrace = Color(hex: 0xBFE8C8)
    static let scopeBackground = Color(hex: 0x0B0B0A)
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

    static let mutedTrack = Color(dark: 0xE5A43B, light: 0xC98418)
    static let soloTrack = Color(dark: 0xF2C94C, light: 0xC99A12)

    // MARK: Text clips

    static let textClipFill = Color(hex: 0x6E54B5)
    static let textClipBorder = Color(hex: 0x5A4496)
    static let textClipBorderSelected = Color(hex: 0x9C84E0)
    static let textClipLabelStrip = Color(hex: 0x4F3B86)
    static let textClipGhost = Color(hex: 0x6E54B5).opacity(0.45)

    // Code editor (Animate scripts).
    static let codeKeyword = Color(dark: 0xC792EA, light: 0x8E3FC7)
    static let codeString = Color(dark: 0xC3E88D, light: 0x4C8A1E)
    static let codeNumber = Color(dark: 0xF78C6C, light: 0xC0562E)
    static let codeComment = Color(dark: 0x676E7B, light: 0x8A8F98)

    // Transparency backdrop (Animate preview).
    static let checkerLight = Color(dark: 0x3A3A38, light: 0xDADAD5)
    static let checkerDark = Color(dark: 0x2C2C2B, light: 0xC4C4BF)

    // Caption tracks.
    static let captionFill = Color(hex: 0xB8862E)
    static let captionBorder = Color(hex: 0x96701F)
    static let captionBorderSelected = Color(hex: 0xF2C46B)
    static let captionText = Color(hex: 0xFFF6E3)
    static let captionGhost = Color(hex: 0xB8862E).opacity(0.45)

    // MARK: Keyframes

    static let keyframe = Color(dark: 0xE8C547, light: 0xC99A12)
    // Changelog tags.
    static let changelogFeature = Color(dark: 0x3BD473, light: 0x1E9E50)
    static let changelogBugFix = Color(dark: 0xF2A93B, light: 0xC27C12)
    static let keyframeSelected = Color(dark: 0xFFFFFF, light: 0x1C1C1A)
    static let curve = Color(dark: 0x3BD473, light: 0x1E9E50)
    static let curveHandle = Color(dark: 0x6FB7F0, light: 0x2F7FC9)
    static let curveGrid = Color(dark: 0x2A2A28, light: 0xBABAB5)

    // MARK: Locking

    /// Diagonal hatching drawn over locked lanes.
    static let lockedHatch = Color(dark: 0x000000, light: 0x000000, darkOpacity: 0.28, lightOpacity: 0.12)
    static let lockedClipDim = Color(dark: 0x121211, light: 0xD4D4CF, darkOpacity: 0.45, lightOpacity: 0.5)

    // MARK: Timeline

    static let rulerTickMajor = Color(dark: 0x6E6E69, light: 0x76766F)
    static let rulerTickMinor = Color(dark: 0x3A3A38, light: 0xA8A8A2)
    static let rulerText = Color(dark: 0x8E8E89, light: 0x56564F)
    static let laneSeparator = Color(dark: 0x1A1A19, light: 0xD4D4CF)
    static let snapGuide = Color(dark: 0xF2C94C, light: 0xD9A514)
    static let dropTarget = Color(dark: 0x3BD473, light: 0x1E9E50).opacity(0.10)

    // MARK: Mixer

    static let meterLow = Color(hex: 0x3BD473)
    static let meterMid = Color(hex: 0xE8C547)
    static let meterHigh = Color(hex: 0xF0605A)
    static let meterTrack = Color(dark: 0x0B0B0A, light: 0xC0C0BB)
    static let meterScale = Color(dark: 0x666662, light: 0x76766F)
    static let faderSlot = Color(dark: 0x0B0B0A, light: 0xAEAEA9)
    static let faderCap = Color(dark: 0xD6D6D2, light: 0xEDEDE9)
    static let faderCapLine = Color(hex: 0x1A1A19)
    static let faderUnity = Color(dark: 0x3A3A38, light: 0x8E8E88)
    static let mixerStrip = Color(dark: 0x1F1F1E, light: 0xCCCCC7)
    static let mixerStripSelected = Color(dark: 0x262B27, light: 0xC0D3C5)
    static let fadeShade = Color(hex: 0x000000).opacity(0.32)
    static let fadeLine = Color(hex: 0xF2F6FA).opacity(0.85)
    static let fadeHandle = Color(hex: 0xF2F6FA)

    // MARK: Shadows

    static let shadow = Color(dark: 0x000000, light: 0x000000, darkOpacity: 0.35, lightOpacity: 0.15)
    /// Behind video frames (the export's live view before its first frame).
    static let videoBlack = Color(hex: 0x000000)

    // MARK: Metrics

    enum Metrics {
        static let panelCornerRadius: CGFloat = 10
        static let clipCornerRadius: CGFloat = 6
        static let controlCornerRadius: CGFloat = 6
        static let rulerHeight: CGFloat = 30
        static let laneHeight: CGFloat = 64
        static let audioLaneHeight: CGFloat = 48
        static let textLaneHeight: CGFloat = 40
        static let captionLaneHeight: CGFloat = 34
        static let titleBarHeight: CGFloat = 40
        /// Room for the window's close / minimize / zoom buttons.
        static let trafficLightInset: CGFloat = 78
        static let laneSpacing: CGFloat = 2
        static let trackHeaderWidth: CGFloat = 124
        static let clipLabelHeight: CGFloat = 16
        static let trimHandleWidth: CGFloat = 7
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
    /// A color that is `dark` in Dark Mode and `light` in Light Mode, resolved for
    /// whichever appearance draws it. Only Theme should call this.
    nonisolated init(dark: UInt32, light: UInt32, darkOpacity: Double = 1, lightOpacity: Double = 1) {
        let dark = NSColor(hex: dark, alpha: darkOpacity), light = NSColor(hex: light, alpha: lightOpacity)
        self.init(nsColor: NSColor(name: nil) { @Sendable appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? light : dark
        })
    }

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

private extension NSColor {
    nonisolated convenience init(hex: UInt32, alpha: Double) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }
}
