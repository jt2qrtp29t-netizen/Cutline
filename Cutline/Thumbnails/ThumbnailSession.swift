import CoreGraphics
import Foundation
import Observation

/// Making a thumbnail for one finished export: finding candidates, asking the local
/// model, then the user's pick, title and save.
@Observable
final class ThumbnailSession: Identifiable {
    enum Phase: Equatable {
        case finding
        case asking(model: String?)
        case ready
        case failed(String)
    }

    let id = UUID()
    let movie: URL
    /// What's said in the export (movie seconds), for context and excited moments.
    let speech: [(time: Double, text: String)]
    @ObservationIgnored let client: OllamaClient

    private(set) var phase = Phase.finding
    private(set) var progress = 0.0
    private(set) var picks: [ThumbnailPicks.Pick] = []
    /// Why the AI model wasn't used, if it wasn't.
    private(set) var note: String?
    private(set) var model: String?
    var selected = 0
    var showsTitle = false
    var title = ""
    var preset = CaptionPreset.boldCenter
    var format = ThumbnailComposer.Format.jpeg
    private(set) var savedURL: URL?
    private(set) var saveMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last thumbnail made, by what it was made from (redraws reuse it).
    @ObservationIgnored private var rendered: (key: String, image: CGImage)?

    init(movie: URL, speech: [(time: Double, text: String)], client: OllamaClient = OllamaClient()) {
        self.movie = movie
        self.speech = speech
        self.client = client
    }

    /// Finds candidates and asks the model (in the background).
    func start() {
        task?.cancel()
        phase = .finding
        progress = 0
        picks = []
        savedURL = nil
        guard FileManager.default.fileExists(atPath: movie.path) else {
            phase = .failed("The exported movie isn't at \(movie.path) anymore.")
            return
        }
        let movie = movie, speech = speech, client = client
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        task = Task { [weak self] in
            do {
                let candidates = try await ThumbnailFinder.candidates(in: movie, speech: speech, progress: report)
                try Task.checkCancellation()
                let model = try? await client.visionModel()
                self?.phase = .asking(model: model)
                let context = speech.map(\.text).joined(separator: " ")
                let result = await ThumbnailPicker.pick(from: candidates, context: context, wantsTitle: true, client: client)
                try Task.checkCancellation()
                self?.finish(with: result)
            } catch is CancellationError {
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(with result: ThumbnailPicks) {
        picks = result.picks
        note = result.note
        model = result.model
        selected = 0
        if let suggested = result.title {
            title = suggested
            showsTitle = true
        }
        phase = result.picks.isEmpty ? .failed("No usable frames were found in this export.") : .ready
    }

    func cancel() { task?.cancel() }

    /// What's said in an export (all audio tracks' transcripts), in movie seconds.
    nonisolated static func speech(in snapshot: ExportSnapshot) -> [(time: Double, text: String)] {
        let range = snapshot.range
        return snapshot.state.captionWords(for: CaptionSettings())
            .filter { $0.start >= range.start && $0.start < range.end }
            .map { (time: ($0.start - range.start).seconds, text: $0.text) }
    }

    var chosen: ThumbnailPicks.Pick? { picks.indices.contains(selected) ? picks[selected] : nil }

    /// The thumbnail as it will be saved.
    func render() -> CGImage? {
        guard let chosen else { return nil }
        let key = "\(chosen.id)|\(showsTitle ? title : "")|\(preset.rawValue)"
        if let rendered, rendered.key == key { return rendered.image }
        guard let image = ThumbnailComposer.compose(frame: chosen.candidate.image, title: showsTitle ? title : nil, style: preset.style)
        else { return nil }
        rendered = (key, image)
        return image
    }

    /// Saves next to the movie: "<movie>-thumbnail.jpg" (or .png).
    @discardableResult
    func save() -> URL? {
        guard let image = render(), let data = ThumbnailComposer.encode(image, as: format) else {
            saveMessage = "The thumbnail couldn't be made."
            return nil
        }
        let base = movie.deletingPathExtension()
        let url = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)-thumbnail")
            .appendingPathExtension(format.fileExtension)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            saveMessage = "Couldn't save: \(error.localizedDescription)"
            return nil
        }
        savedURL = url
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        saveMessage = data.count > ThumbnailComposer.maximumBytes
            ? "Saved (\(size)), but YouTube takes thumbnails up to 2 MB: save as JPEG to fit."
            : "Saved \(url.lastPathComponent) (\(size))."
        return url
    }
}

extension EditorController {
    /// Starts a thumbnail for a finished export (its sound's transcript gives context).
    func makeThumbnail(for job: ExportJob, client: OllamaClient = OllamaClient()) {
        thumbnail?.cancel()
        let session = ThumbnailSession(movie: job.destination, speech: ThumbnailSession.speech(in: job.snapshot), client: client)
        thumbnail = session
        session.start()
    }
}
