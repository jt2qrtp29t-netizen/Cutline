import AppKit

/// Resolving bookmarks and checking for files touches the file system, so
/// results are cached per media item and refreshed when the app is reactivated
/// (the user may have moved or restored files in the meantime).
final class MediaURLCache {
    static let shared = MediaURLCache()

    private var urls: [UUID: URL] = [:]
    private var availability: [UUID: Bool] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MediaURLCache.shared.invalidate() }
        }
    }

    func url(for media: MediaItem) -> URL {
        if let url = urls[media.id] { return url }
        let url = media.resolveURL()
        urls[media.id] = url
        return url
    }

    func isAvailable(_ media: MediaItem) -> Bool {
        if let known = availability[media.id] { return known }
        let exists = FileManager.default.fileExists(atPath: url(for: media).path)
        availability[media.id] = exists
        return exists
    }

    func invalidate() {
        urls.removeAll()
        availability.removeAll()
    }
}
