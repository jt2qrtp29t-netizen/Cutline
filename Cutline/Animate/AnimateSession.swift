import AppKit
import CryptoKit
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

    enum Mode: String { case templates, script }

    var mode = Mode.templates {
        didSet { if mode != oldValue { schedulePreview(after: .zero) } }
    }
    var settings = AnimationTemplate.title.defaults {
        didSet { if settings != oldValue && mode == .templates { schedulePreview() } }
    }
    /// Script mode: the user's Manim code and the scene to render.
    var script = AnimateSession.starterScript {
        didSet {
            guard script != oldValue else { return }
            // Typed here, so it's the user's own: trusted to run.
            if !isLoadingScript { ScriptTrust.approve(script) }
            if !scenes.contains(scene) { scene = scenes.first ?? "" }
            if mode == .script { schedulePreview(after: .milliseconds(1_500)) }
        }
    }
    var scene = "MyScene" {
        didSet { if scene != oldValue && mode == .script { schedulePreview(after: .zero) } }
    }
    var scenes: [String] { ManimEngine.scenes(in: script) }
    /// The timeline clip being edited (Update Clip replaces its animation), if any.
    private(set) var editingClipID: UUID?
    /// A script that came with a project and hasn't been approved on this Mac: shown, not run.
    private(set) var needsTrust = false
    @ObservationIgnored private var isLoadingScript = false

    static let starterScript = """
    from manim import *

    class MyScene(Scene):
        def construct(self):
            title = Text("Hello!", font_size=96, color=YELLOW)
            self.play(Write(title))
            self.play(title.animate.scale(1.2).set_color(WHITE))
            self.wait(1)
            self.play(FadeOut(title))
    """
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

    /// What's being designed, as a render request (template or script).
    func currentRequest(quality: ManimEngine.Quality) -> ManimEngine.Request? {
        switch mode {
        case .templates:
            return request(settings, quality: quality)
        case .script:
            guard !scene.isEmpty, !needsTrust else { return nil }
            let size = frame()
            return ManimEngine.Request(script: script, scene: scene, width: size.width, height: size.height, frameRate: size.fps, quality: quality)
        }
    }

    var currentSource: AnimationSource {
        mode == .templates ? AnimationSource(settings: settings) : AnimationSource(script: script, scene: scene)
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
        guard let request = currentRequest(quality: .preview) else { return }
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

    /// Renders at full quality and puts it on the timeline at the playhead (one undo step),
    /// or, when editing a clip, replaces that clip's animation (`asNew` adds a copy instead).
    func addToTimeline(_ editor: EditorController, asNew: Bool = false) {
        guard let installation, !isAdding, let request = currentRequest(quality: .full) else { return }
        isAdding = true
        let source = currentSource
        let name = mode == .templates ? "\(settings.template.title): \(settings.text.prefix(40))" : "Animation: \(scene)"
        let target = asNew ? nil : editingClipID
        Task { [weak self] in
            defer { self?.isAdding = false }
            do {
                let url = try await ManimEngine.render(request, installation: installation)
                var media = try await MediaImporter.makeItem(for: url)
                media.name = name
                if let target {
                    editor.replaceAnimation(target, with: media, source: source)
                } else {
                    editor.placeAnimation(media, source: source)
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Opens a timeline clip's animation for editing (Update Clip then replaces it).
    func edit(_ clip: Clip) {
        guard let source = clip.animationSource else { return }
        editingClipID = clip.id
        if let settings = source.settings {
            needsTrust = false
            mode = .templates
            self.settings = settings
        } else if let script = source.script {
            // A script from someone else's project isn't run until approved.
            needsTrust = !ScriptTrust.isApproved(script)
            isLoadingScript = true
            self.script = script
            isLoadingScript = false
            scene = source.scene ?? scenes.first ?? ""
            mode = .script
            if !needsTrust { schedulePreview(after: .zero) } else { previewURL = nil; phase = .idle }
        }
    }

    /// The user read the script and chose to run it.
    func approveScript() {
        ScriptTrust.approve(script)
        needsTrust = false
        schedulePreview(after: .zero)
    }

    /// Back to making new animations.
    func stopEditing() { editingClipID = nil }

    /// Saves the current template settings under a name (Parameters-wide, every project).
    func saveTemplate(named name: String) {
        SavedAnimationTemplates.add(name: name, settings: settings)
        savedRevision += 1
    }

    /// Bumped when saved templates change (the gallery redraws).
    private(set) var savedRevision = 0

    func deleteSavedTemplate(_ id: UUID) {
        SavedAnimationTemplates.remove(id)
        savedRevision += 1
    }
}

/// Scripts the user wrote or approved on this Mac (by content), so scripts that arrive in
/// someone else's project aren't run without asking.
nonisolated enum ScriptTrust {
    private static let key = "animate.approvedScripts"

    static func hash(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isApproved(_ script: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(hash(script))
    }

    static func approve(_ script: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        let h = hash(script)
        guard !list.contains(h) else { return }
        list.append(h)
        // Recent ones are enough (each edit while typing is a version).
        UserDefaults.standard.set(Array(list.suffix(500)), forKey: key)
    }
}

/// Template settings the user saved under a name, for every project.
nonisolated enum SavedAnimationTemplates {
    struct Item: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var settings: AnimationSettings
    }

    private static let key = "animate.savedTemplates"

    static var all: [Item] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    private static func store(_ items: [Item]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }

    static func add(name: String, settings: AnimationSettings) {
        store(all + [Item(name: name, settings: settings)])
    }

    static func remove(_ id: UUID) {
        store(all.filter { $0.id != id })
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

    /// Replaces an animation clip's movie with a new render (same start; its length is the
    /// new animation's, up to the next clip), as one undo step.
    func replaceAnimation(_ clipID: UUID, with media: MediaItem, source: AnimationSource) {
        store.edit("Update Animation") { state in
            guard let index = state.trackIndex(ofClip: clipID), let clip = state.clip(clipID) else { return }
            if !state.media.contains(where: { $0.id == media.id }) { state.media.append(media) }
            let next = state.tracks[index].clips.filter { $0.id != clipID && $0.start >= clip.start }.map(\.start).min()
            var length = media.duration
            if let next { length = min(length, next - clip.start) }
            state.updateClip(clipID) { c in
                c.mediaID = media.id
                c.sourceStart = .zero
                c.duration = max(length, Time(ticks: TimelineEditing.minimumClipTicks))
                c.animationSource = source
                c.name = media.name
            }
        }
        selection = [clipID]
    }

    /// Opens an animation clip in the Animate tab.
    func editAnimation(_ clipID: UUID) {
        guard let clip = state.clip(clipID), clip.animationSource != nil else { return }
        workspace = .animate
        animateSession.edit(clip)
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
