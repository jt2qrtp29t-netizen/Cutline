import AppKit
import Foundation
import Observation

/// What an Animate-tab clip was made from (kept so it can be edited and rendered again).
nonisolated struct AnimationSource: Codable, Hashable, Sendable {
    /// Template settings, or nil for a script.
    var settings: AnimationSettings?
    /// The script and scene (custom scripts).
    var script: String?
    var scene: String?
}

/// The Animate tab's work in progress: the template being designed, its live preview,
/// and adding it to the timeline.
@Observable
final class AnimateSession {
    enum Phase: Equatable {
        case checking
        case notInstalled
        case idle
        case rendering(Double)
        case failed(String)
    }

    var settings = AnimationTemplate.title.defaults {
        didSet { if settings != oldValue { schedulePreview() } }
    }
    private(set) var phase = Phase.checking
    /// The latest preview movie (quarter size).
    private(set) var previewURL: URL?
    private(set) var isAdding = false
    private(set) var installation: ManimEngine.Installation?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private let frame: () -> (width: Int, height: Int, fps: Double)

    init(frame: @escaping () -> (width: Int, height: Int, fps: Double)) {
        self.frame = frame
        Task { [weak self] in
            let found = await ManimEngine.find()
            self?.installation = found
            self?.phase = found == nil ? .notInstalled : .idle
            if found != nil { self?.schedulePreview(after: .zero) }
        }
    }

    /// Looks for Manim again (after installing it).
    func recheck() {
        phase = .checking
        Task { [weak self] in
            let found = await ManimEngine.find()
            self?.installation = found
            self?.phase = found == nil ? .notInstalled : .idle
            if found != nil { self?.schedulePreview(after: .zero) }
        }
    }

    func choose(_ template: AnimationTemplate) {
        settings = template.defaults
    }

    /// The typeface as Pango (Manim) names it: family, weight and slant.
    static func pango(_ postScriptName: String) -> (family: String, weight: String, italic: Bool) {
        guard let font = NSFont(name: postScriptName, size: 12) else { return ("Helvetica", "BOLD", false) }
        let family = font.familyName ?? "Helvetica"
        let weight: String = switch NSFontManager.shared.weight(of: font) {
        case ...3: "LIGHT"
        case 4...6: "NORMAL"
        case 7...8: "MEDIUM"
        case 9...10: "BOLD"
        default: "HEAVY"
        }
        let italic = NSFontManager.shared.traits(of: font).contains(.italicFontMask)
        return (family, weight, italic)
    }

    func request(_ settings: AnimationSettings, quality: ManimEngine.Quality) -> ManimEngine.Request {
        let font = Self.pango(settings.fontName)
        var effective = settings
        effective.italic = settings.italic || font.italic
        let size = frame()
        return ManimEngine.Request(script: TemplateProgram.script, scene: TemplateProgram.scene, width: size.width, height: size.height,
                                   frameRate: size.fps, quality: quality,
                                   parameters: effective.parameters(family: font.family, weight: font.weight))
    }

    private func schedulePreview(after delay: Duration = .milliseconds(500)) {
        guard let installation else { return }
        previewTask?.cancel()
        let request = request(settings, quality: .preview)
        let report: @Sendable (Int, Double) -> Void = { [weak self] _, fraction in
            Task { @MainActor in
                if case .rendering = self?.phase { self?.phase = .rendering(fraction) }
            }
        }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.phase = .rendering(0)
            do {
                let url = try await ManimEngine.render(request, installation: installation, progress: report)
                guard !Task.isCancelled else { return }
                self?.previewURL = url
                self?.phase = .idle
            } catch is CancellationError {
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Renders at full quality and puts it on the timeline at the playhead (one undo step).
    func addToTimeline(_ editor: EditorController) {
        guard let installation, !isAdding else { return }
        isAdding = true
        let settings = settings
        let request = request(settings, quality: .full)
        Task { [weak self] in
            defer { self?.isAdding = false }
            do {
                let url = try await ManimEngine.render(request, installation: installation)
                var media = try await MediaImporter.makeItem(for: url)
                media.name = "\(settings.template.title): \(settings.text.prefix(40))"
                editor.placeAnimation(media, source: AnimationSource(settings: settings))
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }
}

extension EditorController {
    /// Adds a rendered animation at the playhead, on the topmost video track that's free
    /// there (a new one above if none is), as one undo step.
    func placeAnimation(_ media: MediaItem, source: AnimationSource) {
        let at = playback.currentTime
        var placed: UUID?
        store.edit("Add Animation") { state in
            if !state.media.contains(where: { $0.id == media.id }) { state.media.append(media) }
            let range = TimeRange(start: at, end: at + media.duration)
            let free = state.trackIndices(of: .video).reversed().first { index in
                !state.tracks[index].isLocked && !state.tracks[index].clips.contains { $0.range.overlaps(range) }
            }
            // Above everything if the top track is busy there.
            let target = free.flatMap { state.trackIndices(of: .video).last == $0 ? $0 : nil } ?? state.appendTrack(.video)
            let ids = TimelineEditing.place(media, at: at, onTrack: target, in: &state)
            for id in ids { state.updateClip(id) { $0.animationSource = source; $0.name = media.name } }
            placed = ids.first
        }
        if let placed { selection = [placed] }
    }

    /// The Animate tab's session (made on first use).
    var animateSession: AnimateSession {
        if let existing = animate { return existing }
        let session = AnimateSession { [weak self] in
            guard let self else { return (1920, 1080, 30) }
            return (self.state.settings.width, self.state.settings.height, Double(self.state.settings.frameRate))
        }
        animate = session
        return session
    }
}
