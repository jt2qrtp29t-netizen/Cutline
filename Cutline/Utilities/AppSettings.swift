import Foundation
import Observation

/// App-wide preferences shared by every editor window, edited in the Parameters
/// window (⌘,) and kept in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private static let defaults = UserDefaults.standard

    private static func value<T>(_ key: String, default fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    // MARK: General

    /// Show the welcome window when Cutline starts.
    var showWelcomeAtLaunch: Bool = value("general.showWelcome", default: true) {
        didSet { Self.defaults.set(showWelcomeAtLaunch, forKey: "general.showWelcome") }
    }

    /// Keep checking for media files that go missing (or come back) while Cutline is
    /// in use. When off, files are only checked when you switch back to Cutline.
    var watchForOfflineMedia: Bool = value("media.watchOffline", default: true) {
        didSet { Self.defaults.set(watchForOfflineMedia, forKey: "media.watchOffline") }
    }

    // MARK: Timeline

    /// Whether snapping starts on in newly opened projects (⇧⌘N toggles it per window).
    var snapByDefault: Bool = value("timeline.snapByDefault", default: true) {
        didSet { Self.defaults.set(snapByDefault, forKey: "timeline.snapByDefault") }
    }

    /// How close (in points) an edge must come to snap.
    var snapDistance: Double = value("timeline.snapDistance", default: 8.0) {
        didSet { Self.defaults.set(snapDistance, forKey: "timeline.snapDistance") }
    }
    static let snapDistanceRange = 2.0...24.0

    /// Scroll the timeline during playback so the playhead stays in view.
    var followPlayhead: Bool = value("timeline.followPlayhead", default: true) {
        didSet { Self.defaults.set(followPlayhead, forKey: "timeline.followPlayhead") }
    }

    /// Pointer travel (points) per frame when Option-dragging the playhead.
    var fineScrubPointsPerFrame: Double = value("timeline.fineScrubPointsPerFrame", default: 10.0) {
        didSet { Self.defaults.set(fineScrubPointsPerFrame, forKey: "timeline.fineScrubPointsPerFrame") }
    }
    static let fineScrubRange = 3.0...40.0

    // MARK: Playback

    /// Universal mute: silences playback in every project.
    var isMuted: Bool = value("audio.muted", default: false) {
        didSet { Self.defaults.set(isMuted, forKey: "audio.muted") }
    }

    /// Play the sound under the playhead while scrubbing.
    var scrubAudio: Bool = value("playback.scrubAudio", default: true) {
        didSet { Self.defaults.set(scrubAudio, forKey: "playback.scrubAudio") }
    }

    /// Which files playback reads: originals, or optimized or proxy copies where they exist.
    /// Exports always use the originals.
    var playbackMedia: PlaybackMedia = PlaybackMedia(rawValue: value("playback.media", default: "original")) ?? .original {
        didSet {
            Self.defaults.set(playbackMedia.rawValue, forKey: "playback.media")
            NotificationCenter.default.post(name: .generatedMediaChanged, object: Set<UUID>())
        }
    }

    /// Make optimized (ProRes 422) copies of video files as they're imported.
    var createOptimizedOnImport: Bool = value("media.optimizeOnImport", default: false) {
        didSet { Self.defaults.set(createOptimizedOnImport, forKey: "media.optimizeOnImport") }
    }

    /// Make proxy (half size ProRes 422 Proxy) copies of video files as they're imported.
    var createProxyOnImport: Bool = value("media.proxyOnImport", default: false) {
        didSet { Self.defaults.set(createProxyOnImport, forKey: "media.proxyOnImport") }
    }

    // MARK: Effects

    /// Length of newly added transitions, in seconds.
    var transitionLength: Double = value("transitions.duration", default: Transition.defaultDuration.seconds) {
        didSet { Self.defaults.set(transitionLength, forKey: "transitions.duration") }
    }
    static let transitionLengthRange = 0.1...3.0

    // MARK: Mouse

    /// Horizontal scrolling (e.g. a mouse's thumb wheel) switches workspace tabs.
    var scrollSwitchesTabs: Bool = value("mouse.scrollSwitchesTabs", default: true) {
        didSet { Self.defaults.set(scrollSwitchesTabs, forKey: "mouse.scrollSwitchesTabs") }
    }

    /// Scrolling right moves to the tab on the left instead.
    var reverseTabScrolling: Bool = value("mouse.reverseTabScrolling", default: false) {
        didSet { Self.defaults.set(reverseTabScrolling, forKey: "mouse.reverseTabScrolling") }
    }

    /// Puts every setting back to its default.
    func resetToDefaults() {
        for key in ["general.showWelcome", "media.watchOffline", "timeline.snapByDefault", "timeline.snapDistance",
                    "timeline.followPlayhead", "timeline.fineScrubPointsPerFrame", "playback.scrubAudio",
                    "transitions.duration", "mouse.scrollSwitchesTabs", "mouse.reverseTabScrolling",
                    "playback.media", "media.optimizeOnImport", "media.proxyOnImport"] {
            Self.defaults.removeObject(forKey: key)
        }
        showWelcomeAtLaunch = true
        watchForOfflineMedia = true
        snapByDefault = true
        snapDistance = 8
        followPlayhead = true
        fineScrubPointsPerFrame = 10
        scrubAudio = true
        transitionLength = Transition.defaultDuration.seconds
        scrollSwitchesTabs = true
        reverseTabScrolling = false
        playbackMedia = .original
        createOptimizedOnImport = false
        createProxyOnImport = false
    }
}
