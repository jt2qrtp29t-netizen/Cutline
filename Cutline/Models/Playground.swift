import CryptoKit
import Foundation

/// A group of clips that are variants of the same idea (A, B, C…), compared in the preview.
nonisolated struct VariantGroup: Identifiable, Codable, Hashable, Sendable {
    enum Compare: String, Codable, Sendable {
        /// Only the active variant is shown.
        case toggle
        /// The variants side by side, each in its own vertical slice of the frame.
        case split
    }

    var id = UUID()
    var clipIDs: [UUID]
    var active = 0
    var compare = Compare.toggle

    static func letter(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + index % 26)))
    }
}

/// A named checkpoint of the scratch timeline.
nonisolated struct PlaygroundSnapshot: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var date: Date
    var project: ProjectState
    var variants: [VariantGroup]
}

/// Everything in a project's Playground. It never lives in the project file: it's
/// saved on its own (see `PlaygroundFile`), so nothing done here can touch the project.
nonisolated struct PlaygroundState: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version = PlaygroundState.currentVersion
    /// The scratch timeline: its own tracks, clips and media list.
    var project: ProjectState
    /// For clips sent from Edit: the Edit clip each copy came from. Only a hint for
    /// "apply to original"; the copy never depends on it.
    var origins: [UUID: UUID] = [:]
    var variants: [VariantGroup] = []
    var snapshots: [PlaygroundSnapshot] = []
    /// Lab experiments switched off in this Playground (they're skipped when rendering).
    var disabledExperiments: Set<String> = []

    /// An empty Playground matching the project's frame size and rate.
    static func empty(like settings: ProjectSettings) -> PlaygroundState {
        var project = ProjectState(settings: settings)
        project.settings.name = "Playground"
        return PlaygroundState(project: project)
    }

    init(project: ProjectState) {
        self.project = project
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        project = try c.decode(ProjectState.self, forKey: .project)
        origins = try c.decodeIfPresent([UUID: UUID].self, forKey: .origins) ?? [:]
        variants = try c.decodeIfPresent([VariantGroup].self, forKey: .variants) ?? []
        snapshots = try c.decodeIfPresent([PlaygroundSnapshot].self, forKey: .snapshots) ?? []
        disabledExperiments = try c.decodeIfPresent(Set<String>.self, forKey: .disabledExperiments) ?? []
    }

    /// Variant groups with clips that no longer exist removed (e.g. after undo).
    var liveVariants: [VariantGroup] {
        let ids = Set(project.allClips.map(\.id))
        return variants.compactMap { group in
            var group = group
            group.clipIDs = group.clipIDs.filter(ids.contains)
            guard group.clipIDs.count > 1 else { return nil }
            group.active = min(group.active, group.clipIDs.count - 1)
            return group
        }
    }
}

/// Where a project's Playground is saved: Application Support/Cutline/Playgrounds,
/// one file per project, written atomically.
nonisolated enum PlaygroundFile {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutline/Playgrounds", isDirectory: true)
    }

    /// The key for a project: its ID, or for older projects one derived from its file
    /// location (so it stays the same each time the project is opened).
    static func key(projectID: UUID?, fileURL: URL?) -> String {
        if let projectID { return projectID.uuidString }
        if let fileURL {
            let digest = SHA256.hash(data: Data(fileURL.standardizedFileURL.path.utf8))
            return "path-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        }
        return "unsaved-" + UUID().uuidString
    }

    static func url(for key: String, in folder: URL = folder) -> URL {
        folder.appendingPathComponent("\(key).cutline-playground")
    }

    enum LoadResult {
        case loaded(PlaygroundState)
        case none
        /// The file couldn't be read; it was moved aside (to `backup`) and a fresh
        /// Playground is used.
        case damaged(backup: URL)
    }

    static func load(key: String, in folder: URL = folder) -> LoadResult {
        let url = url(for: key, in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try JSONDecoder().decode(PlaygroundState.self, from: data))
        } catch {
            let backup = folder.appendingPathComponent("\(key).damaged-\(Int(Date().timeIntervalSince1970)).cutline-playground")
            try? FileManager.default.moveItem(at: url, to: backup)
            return .damaged(backup: backup)
        }
    }

    static func save(_ state: PlaygroundState, key: String, in folder: URL = folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url(for: key, in: folder), options: .atomic)
    }

    static func delete(key: String, in folder: URL = folder) {
        try? FileManager.default.removeItem(at: url(for: key, in: folder))
    }
}
