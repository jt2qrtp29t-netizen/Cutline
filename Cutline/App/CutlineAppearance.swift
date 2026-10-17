import AppKit
import SwiftUI

/// Cutline's look: dark by default, light when Parameters → General → Light mode is
/// on. The system's own appearance setting is never followed.
enum CutlineAppearance {
    /// Sets the app-wide appearance, which menus, alerts and open panels use too.
    static func apply() {
        NSApp.appearance = NSAppearance(named: AppSettings.shared.lightMode ? .aqua : .darkAqua)
    }
}

extension View {
    /// The color scheme and accent every Cutline window uses; switches live when the
    /// Light mode parameter changes.
    func cutlineAppearance() -> some View {
        modifier(CutlineAppearanceModifier())
    }
}

private struct CutlineAppearanceModifier: ViewModifier {
    @Bindable private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(settings.lightMode ? .light : .dark)
            .tint(Theme.accent)
            .onChange(of: settings.lightMode) { CutlineAppearance.apply() }
    }
}
