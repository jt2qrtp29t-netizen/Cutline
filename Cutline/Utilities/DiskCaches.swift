import Foundation

/// The files Cutline keeps in its Caches folder to avoid repeating work. Each file is
/// named after its media item and the source file's identity (`<id>-<stamp>…`), so a
/// changed source is never paired with an outdated file.
nonisolated enum DiskCache: String, CaseIterable, Identifiable, Sendable {
    /// The sound of movie files, decoded for playback.
    case audio = "AudioProxies"
    /// Waveform peaks for the timeline and media bin.
    case waveforms = "Waveforms"
    /// Optimized and proxy media.
    case media = "Media"
    /// The sound of speed-ramped and tape-speed clips, rendered ahead of time.
    case retimed = "RetimedAudio"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: "Audio previews"
        case .waveforms: "Waveforms"
        case .media: "Optimized and proxy media"
        case .retimed: "Speed-changed audio"
        }
    }

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline", isDirectory: true)
    }

    var folder: URL { Self.root.appendingPathComponent(rawValue, isDirectory: true) }

    /// Remade automatically when needed, so files unused for a while are removed.
    /// (Optimized and proxy media are only made when asked for, so they're kept.)
    var isRemadeAutomatically: Bool { self != .media }

    /// Identity of a source file: its modification time and size.
    static func stamp(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let size = values.fileSize else { return nil }
        return "\(Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0))-\(size)"
    }

    private func files() -> [URL] { Self.files(in: folder) }

    private static func files(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                       options: .skipsHiddenFiles)) ?? []
    }

    func size() -> Int64 {
        files().reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        for file in files() { try? FileManager.default.removeItem(at: file) }
    }

    /// Marks a file as just used, so it isn't pruned as unused.
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Removes files made from older versions of a source (a newer one exists for the
    /// same item and kind) and, for caches that are remade automatically, files unused
    /// for `maxAge`.
    func prune(maxAge: TimeInterval = 60 * 24 * 3600, now: Date = Date()) {
        Self.prune(folder, removingUnused: isRemadeAutomatically, maxAge: maxAge, now: now)
    }

    static func prune(_ folder: URL, removingUnused: Bool, maxAge: TimeInterval = 60 * 24 * 3600, now: Date = Date()) {
        // "<uuid>-<seconds>-<size>[-kind].ext" → group by uuid and kind.
        var newest: [String: (url: URL, date: Date)] = [:]
        var stale: [URL] = []
        for file in files(in: folder) {
            let name = file.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "-")
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if removingUnused, now.timeIntervalSince(date) > maxAge {
                stale.append(file)
                continue
            }
            // Files named by content (not by source) have no older versions to replace.
            guard name.count > 36, UUID(uuidString: String(name.prefix(36))) != nil, parts.count >= 7 else { continue }
            let kind = parts.count > 7 ? parts[7...].joined(separator: "-") : ""
            let group = "\(name.prefix(36))|\(kind)|\(file.pathExtension)"
            if let other = newest[group] {
                // Two versions for one source: keep the one made from the newer file.
                let (keep, drop) = sourceSeconds(name) >= sourceSeconds(other.url.deletingPathExtension().lastPathComponent)
                    ? (file, other.url) : (other.url, file)
                stale.append(drop)
                newest[group] = (keep, keep == file ? date : other.date)
            } else {
                newest[group] = (file, date)
            }
        }
        for file in stale { try? FileManager.default.removeItem(at: file) }
    }

    private static func sourceSeconds(_ name: String) -> Int {
        let parts = name.split(separator: "-")
        return parts.count > 5 ? Int(parts[5]) ?? 0 : 0
    }

    /// Prunes every cache, off the main thread.
    static func pruneAll() {
        Task.detached(priority: .background) {
            for cache in DiskCache.allCases { cache.prune() }
        }
    }
}
