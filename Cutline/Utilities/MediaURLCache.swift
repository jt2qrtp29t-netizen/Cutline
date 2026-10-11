import AppKit
import Observation

extension Notification.Name {
    /// Posted when media files go missing or come back; `object` is the set of affected media IDs.
    static let mediaAvailabilityChanged = Notification.Name("app.cutline.mediaAvailabilityChanged")
}

/// Resolves media file locations and tracks which files are missing ("offline").
///
/// Resolving bookmarks and checking for files touches the file system, so results
/// are cached per media item. They're rechecked every couple of seconds, when a
/// disk is mounted or ejected, and when the app is reactivated, so a file that is
/// moved, deleted or on an unplugged drive shows as offline right away, and comes
/// back online when it reappears. Views that ask `isAvailable` update on changes.
@Observable
final class MediaURLCache {
    static let shared = MediaURLCache()

    /// Bumped whenever any media item's availability changes.
    private(set) var revision = 0

    @ObservationIgnored private var urls: [UUID: URL] = [:]
    @ObservationIgnored private var availability: [UUID: Bool] = [:]
    @ObservationIgnored private var known: [UUID: MediaItem] = [:]
    @ObservationIgnored private var timer: Timer?

    private init() {
        let recheck: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { MediaURLCache.shared.recheck() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main, using: recheck)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: recheck)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AppSettings.shared.watchForOfflineMedia else { return }
                MediaURLCache.shared.recheck()
            }
        }
    }

    func url(for media: MediaItem) -> URL {
        if let url = urls[media.id], known[media.id] == media { return url }
        known[media.id] = media
        let url = media.resolveURL()
        urls[media.id] = url
        availability[media.id] = nil
        return url
    }

    func isAvailable(_ media: MediaItem) -> Bool {
        _ = revision
        let url = url(for: media)
        if let cached = availability[media.id] { return cached }
        let exists = FileManager.default.fileExists(atPath: url.path)
        availability[media.id] = exists
        return exists
    }

    /// The media items among `items` whose files are missing.
    func offline(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { !isAvailable($0) }
    }

    /// Re-resolves every known media item and announces the ones whose availability changed.
    func recheck() {
        var changed = Set<UUID>()
        for (id, media) in known {
            let url = media.resolveURL()
            let exists = FileManager.default.fileExists(atPath: url.path)
            // Only a known earlier state can have changed; an item seen for the first time
            // (or after its entry was refreshed) isn't announced.
            let previousURL = urls[id]
            let wasAvailable = availability[id] ?? previousURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? exists
            if exists != wasAvailable || (previousURL != nil && url != previousURL) { changed.insert(id) }
            urls[id] = url
            availability[id] = exists
        }
        guard !changed.isEmpty else { return }
        ThumbnailCache.shared.forget(changed)
        WaveformCache.shared.forget(changed)
        revision += 1
        NotificationCenter.default.post(name: .mediaAvailabilityChanged, object: changed)
    }

}
