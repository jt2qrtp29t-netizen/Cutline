import AppKit
import SwiftUI
import Testing
@testable import Cutline

/// Light mode: Theme colors with a light variant change with the appearance; the
/// ones meant to look the same (clips, the video canvas) don't.
@MainActor
struct ThemeAppearanceTests {
    private func resolved(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return color.resolve(in: environment)
    }

    @Test func surfacesAndTextFollowTheColorScheme() {
        let dark = resolved(Theme.background, .dark), light = resolved(Theme.background, .light)
        #expect(dark.red < 0.15 && light.red > 0.75)
        #expect(resolved(Theme.textPrimary, .dark).red > 0.9)
        #expect(resolved(Theme.textPrimary, .light).red < 0.15)
    }

    @Test func opacityVariesWithTheAppearanceWhereAsked() {
        #expect(abs(resolved(Theme.shadow, .dark).opacity - 0.35) < 0.01)
        #expect(abs(resolved(Theme.shadow, .light).opacity - 0.15) < 0.01)
        // .opacity() applied on top of an adaptive color keeps working.
        #expect(abs(resolved(Theme.accentMuted, .light).opacity - 0.18) < 0.01)
    }

    @Test func clipsAndCanvasLookTheSameInBothModes() {
        #expect(resolved(Theme.clipFill, .dark) == resolved(Theme.clipFill, .light))
        #expect(resolved(Theme.canvas, .dark) == resolved(Theme.canvas, .light))
    }

    @Test func appKitViewsResolveByTheirAppearance() {
        let color = NSColor(Theme.recessed)
        var dark = 0.0, light = 0.0
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = color.usingColorSpace(.sRGB)!.redComponent }
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = color.usingColorSpace(.sRGB)!.redComponent }
        #expect(dark < 0.15 && light > 0.7)
    }
}
