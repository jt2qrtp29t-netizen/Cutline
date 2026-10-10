import AppKit

/// Recently opened projects, merged from AppKit's recent documents and our own
/// list (so projects created from the launch window appear immediately).
enum RecentProjects {
    private static let key = "recentProjectPaths"
    private static let limit = 12

    struct Entry: Identifiable, Hashable {
        let url: URL
        let modified: Date?
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
        var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    }

    static func note(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func entries() -> [Entry] {
        let own = (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
        let system = NSDocumentController.shared.recentDocumentURLs
        var seen = Set<String>()
        var result: [Entry] = []
        for url in own + system where url.pathExtension == "cutline" {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
            seen.insert(path)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            result.append(Entry(url: url, modified: modified))
        }
        return result.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
