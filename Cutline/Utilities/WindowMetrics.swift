import AppKit

/// Project window sizes. The side panels of the Effects, Color and Audio tabs need room
/// beside the preview, so a project window is never narrower than about 60% of a 27″
/// display (2560 points wide at its standard resolution): 1536 points. On a smaller
/// screen that would be wider than the screen, the minimum is the screen's own width.
enum WindowMetrics {
    static let preferredMinimumWidth: CGFloat = 1536

    static var minimumWidth: CGFloat {
        let screen = NSScreen.main?.visibleFrame.width ?? preferredMinimumWidth
        return min(preferredMinimumWidth, screen)
    }

    /// New windows open a little wider than the minimum.
    static var defaultWidth: CGFloat {
        let screen = NSScreen.main?.visibleFrame.width ?? 1680
        return min(1680, screen)
    }
}
