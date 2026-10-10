import Foundation

/// The outcome of a finished export.
nonisolated struct ExportResult: Sendable {
    let url: URL
    let frames: Int
    /// Things that didn't render as intended (e.g. a Labs shader that failed).
    let warnings: [String]
}

/// Runs one export: mixes the audio, renders the video off the main thread into a
/// temporary file next to the destination, then moves it into place. A canceled or
/// failed export never leaves a partial file at the destination.
enum ExportRunner {
    /// - Parameter progress: 0...1 overall, plus frames written so far.
    static func run(_ snapshot: ExportSnapshot, to destination: URL, cancellation: ExportCancellation,
                    progress: @escaping @Sendable (Double, Int) -> Void) async throws -> ExportResult {
        guard snapshot.range.duration > .zero, snapshot.frameCount > 0 else { throw ExportError.emptyTimeline }

        // A private folder on the same volume as the destination, so the final move is atomic.
        let fileManager = FileManager.default
        let workFolder: URL
        do {
            workFolder = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                             appropriateFor: destination, create: true)
        } catch {
            throw ExportError.setupFailed("the destination folder can’t be written to (\(error.localizedDescription)).")
        }
        defer { try? fileManager.removeItem(at: workFolder) }

        // 1. The audio mix (about 5% of the work).
        let mix = workFolder.appendingPathComponent("mix.caf")
        try await ExportAudioMixer.render(snapshot, to: mix, cancellation: cancellation) { fraction in
            progress(fraction * 0.05, 0)
        }

        // 2. The video, rendered by the preview's compositor, plus the encoded audio.
        let movie = workFolder.appendingPathComponent("export.\(snapshot.settings.effectiveContainer.fileExtension)")
        let total = snapshot.frameCount
        try await Task.detached(priority: .userInitiated) {
            try await ExportRenderer.render(snapshot, audio: mix, to: movie, cancellation: cancellation) { frames in
                progress(0.05 + 0.95 * Double(frames) / Double(total), frames)
            }
        }.value
        if cancellation.isCancelled { throw ExportError.cancelled }

        // 3. Into place in one step (replacing an older file only now that the new one is complete).
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: movie)
            } else {
                try fileManager.moveItem(at: movie, to: destination)
            }
        } catch {
            throw ExportError.writingFailed("the finished file couldn’t be saved (\(error.localizedDescription)).")
        }

        let warnings = snapshot.labEffects.compactMap { item -> String? in
            guard let error = LabStatus.currentError(item.effect.id) else { return nil }
            let name = ExperimentRegistry.experiment(item.effect.experimentID)?.name ?? item.effect.experimentID
            return "“\(name)” on “\(item.clip)” didn’t render (\(error)), so that clip was exported without it."
        }
        return ExportResult(url: destination, frames: total, warnings: warnings)
    }
}
