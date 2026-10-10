import AppKit

/// Which timeline to export.
enum ExportSource: String, CaseIterable, Identifiable {
    case edit, playground
    var id: String { rawValue }
    var title: String { self == .edit ? "Edit Timeline" : "Playground" }
}

/// For a Playground clip with variants: what to export.
enum VariantExport: String, CaseIterable, Identifiable {
    /// As the Playground currently shows it.
    case asShown
    /// Only the selected variant.
    case selected
    /// Each variant as its own file.
    case all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .asShown: "As Shown"
        case .selected: "This Variant Only"
        case .all: "Every Variant, Separately"
        }
    }
}

extension PlaygroundSession {
    /// The scratch timeline as it's drawn (variants and Labs switches applied, never the
    /// "before" view), optionally showing one variant of one group alone.
    func renderedState(showing variant: (group: UUID, index: Int)? = nil) -> ProjectState {
        var state = editor.state
        for var group in PlaygroundState(project: state).withVariants(variants).liveVariants {
            if let variant, variant.group == group.id {
                group.compare = .toggle
                group.active = variant.index
            }
            group.apply(to: &state)
        }
        if !disabledExperiments.isEmpty { state.disableExperiments(disabledExperiments) }
        return state
    }
}

extension EditorController {
    /// The editor holding a source's timeline (the Playground's is created if needed).
    func exportEditor(for source: ExportSource) -> EditorController {
        source == .edit ? self : ensurePlayground().editor
    }

    func exportSettings(for source: ExportSource) -> ExportSettings {
        exportEditor(for: source).state.exportSettings
    }

    /// Changes a source's saved export settings. A run of changes is one undo step, in
    /// that source's own history (the Playground's never reaches the project).
    func updateExportSettings(for source: ExportSource, _ body: @escaping (inout ExportSettings) -> Void) {
        let target = exportEditor(for: source)
        target.store.edit("Change Export Settings", coalescingKey: "export-settings") { body(&$0.exportSettings) }
    }

    /// The variant group of the clip selected in the Playground, if any.
    var selectedPlaygroundVariantGroup: VariantGroup? {
        guard let playground, let clip = playground.editor.selectedClips.first,
              playground.editor.selectedClips.count == 1 else { return nil }
        return playground.variantGroup(containing: clip.id)
    }

    /// The default file name (without extension) for a source.
    func defaultExportName(for source: ExportSource) -> String {
        let base = projectFileURL?.deletingPathExtension().lastPathComponent ?? state.settings.name
        return source == .playground ? base + "-playground" : base
    }

    /// The folder exports go to: the last one used, or Movies.
    func exportFolder(for source: ExportSource) -> URL {
        if let path = exportSettings(for: source).folderPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }

    /// The range the settings ask for, on the source's timeline (nil = nothing to export).
    func exportRange(for source: ExportSource) -> TimeRange? {
        let editor = exportEditor(for: source)
        let settings = editor.state.exportSettings
        let state = source == .playground ? ensurePlayground().renderedState() : editor.state
        return settings.timeRange(timelineDuration: state.duration, selection: editor.selectedClips)
            .map { ExportSnapshot.snapped($0, fps: settings.frameRate(for: state.settings)) }
    }

    /// Problems to confirm before exporting: missing media files and LUTs in the range.
    func exportPreflightWarnings(for source: ExportSource) -> [String] {
        let state = source == .playground ? ensurePlayground().renderedState() : state
        guard let range = exportRange(for: source) else { return [] }
        let clips = state.allClips.filter { $0.range.overlaps(range) }
        var warnings: [String] = []
        let usedMedia = Set(clips.filter { !$0.isText && $0.generator == nil }.map(\.mediaID))
        for media in state.media where usedMedia.contains(media.id) && !MediaURLCache.shared.isAvailable(media) {
            warnings.append("“\(media.name)” is missing. Its clips will export as a red Media Offline frame (and silence).")
        }
        for clip in clips {
            if let lut = clip.color.lut, !LUTLibrary.shared.isAvailable(lut) {
                warnings.append("The LUT “\(lut.name)” on “\(clip.name)” can’t be found. The clip will export without it.")
            }
        }
        return warnings
    }

    /// The jobs for an export: one, or one per variant. Nothing in the project changes.
    /// Throws `ExportError.emptyTimeline` if there's nothing in the range.
    func makeExportJobs(source: ExportSource, fileName: String, folder: URL,
                        variants: VariantExport = .asShown) throws -> [ExportJob] {
        let editor = exportEditor(for: source)
        let settings = editor.state.exportSettings
        guard let range = exportRange(for: source) else { throw ExportError.emptyTimeline }

        var choices: [(suffix: String, state: ProjectState)] = []
        if source == .playground, let playground, let group = selectedPlaygroundVariantGroup, variants != .asShown {
            let selectedIndex = editor.selectedClips.first.flatMap { group.clipIDs.firstIndex(of: $0.id) } ?? group.active
            let indices = variants == .all ? Array(group.clipIDs.indices) : [selectedIndex]
            choices = indices.map { ("-" + VariantGroup.letter($0), playground.renderedState(showing: (group.id, $0))) }
        } else {
            let state = source == .playground ? ensurePlayground().renderedState() : editor.state
            choices = [("", state)]
        }

        let ext = settings.effectiveContainer.fileExtension
        return choices.map { choice in
            var state = choice.state
            // The frame size and rate always come from the project, even for the Playground.
            state.settings.width = self.state.settings.width
            state.settings.height = self.state.settings.height
            let urls = Dictionary(uniqueKeysWithValues: state.media.map { ($0.id, MediaURLCache.shared.url(for: $0)) })
            let snapshot = ExportSnapshot(state: state, urls: urls, range: range, settings: settings)
            let name = fileName + choice.suffix
            return ExportJob(title: name, sourceName: source == .edit ? "Edit" : "Playground", isPlayground: source == .playground,
                             snapshot: snapshot, destination: folder.appendingPathComponent("\(name).\(ext)"), project: self)
        }
    }
}
