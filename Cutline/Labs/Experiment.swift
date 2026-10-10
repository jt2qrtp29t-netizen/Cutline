import CoreImage
import Foundation

/// One parameter of an experiment. Values are plain numbers and can be keyframed.
nonisolated struct ExperimentParameter: Identifiable, Sendable {
    let id: String
    let name: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    /// Shown after the value, e.g. "°" or "px".
    var unit = ""
}

/// What an experiment renders with.
nonisolated struct ExperimentContext {
    /// The clip's picture (effects), or nil (generators).
    let input: CIImage?
    /// The frame, in render pixels.
    let canvas: CGRect
    /// Seconds since the start of the clip.
    let time: Double
    let values: [String: Double]
    /// The effect's code, for experiments that take some.
    let source: String?

    func value(_ id: String) -> Double { values[id] ?? 0 }
}

/// A Labs experiment. To add one, append an `Experiment(...)` to
/// `ExperimentRegistry.builtIn`: an ID, a name, a one-line description, its parameters
/// and a render function. It's then listed in Labs, saved with clips, keyframable, and
/// rendered by the same pipeline as everything else (so it can be promoted to Edit).
nonisolated struct Experiment: Identifiable, Sendable {
    enum Kind: Sendable {
        /// Makes a picture by itself: added to the timeline as a generator clip.
        case generator
        /// Changes a clip's picture.
        case effect
    }

    let id: String
    let name: String
    let summary: String
    let kind: Kind
    let symbolName: String
    var parameters: [ExperimentParameter] = []
    /// Starting code for experiments that take code (nil for the rest).
    var defaultSource: String?
    /// Renders one frame. Throwing marks the item as failing; the clip then shows
    /// unchanged (or, for a generator, nothing).
    let render: @Sendable (ExperimentContext) throws -> CIImage

    func defaultValues() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.defaultValue) })
    }

    func parameter(_ id: String) -> ExperimentParameter? { parameters.first { $0.id == id } }
}

enum ExperimentError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

/// All Labs experiments.
nonisolated enum ExperimentRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var extra: [Experiment] = []

    static var all: [Experiment] {
        lock.lock()
        defer { lock.unlock() }
        return builtIn + extra
    }

    static func experiment(_ id: String) -> Experiment? {
        all.first { $0.id == id }
    }

    /// Adds an experiment at runtime (used by tests).
    static func register(_ experiment: Experiment) {
        lock.lock()
        extra.removeAll { $0.id == experiment.id }
        extra.append(experiment)
        lock.unlock()
    }
}

/// Failures of Labs items, by `LabEffect.id`, for showing next to them. Rendering
/// reports from the compositor's queue; the UI reads `errors` on the main thread.
@Observable
final class LabStatus {
    static let shared = LabStatus()
    private(set) var errors: [UUID: String] = [:]

    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var latest: [UUID: String] = [:]

    /// Records the outcome of rendering an item (nil = it worked).
    nonisolated static func report(_ id: UUID, error: String?) {
        lock.lock()
        let changed = latest[id] != error
        if changed { latest[id] = error }
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { LabStatus.shared.errors[id] = error }
        }
    }

    nonisolated static func currentError(_ id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return latest[id]
    }
}

/// Renders Labs items. Every failure falls back to the unchanged picture.
nonisolated enum LabRenderer {
    /// A generator clip's picture, or nil if it's switched off or failing.
    static func generate(_ effect: LabEffect, canvas: CGRect, time: Double) -> CIImage? {
        guard effect.isEnabled else { return nil }
        return run(effect, input: nil, canvas: canvas, time: time)
    }

    /// A clip's picture with its Labs effects applied in order.
    static func apply(_ effects: [LabEffect], to image: CIImage, canvas: CGRect, time: Double) -> CIImage {
        var image = image
        for effect in effects where effect.isEnabled {
            if let result = run(effect, input: image, canvas: canvas, time: time) { image = result }
        }
        return image
    }

    private static func run(_ effect: LabEffect, input: CIImage?, canvas: CGRect, time: Double) -> CIImage? {
        guard let experiment = ExperimentRegistry.experiment(effect.experimentID) else {
            LabStatus.report(effect.id, error: "“\(effect.experimentID)” isn’t available in this version of Cutline.")
            return nil
        }
        var values = experiment.defaultValues()
        let offset = Time(seconds: time)
        for parameter in experiment.parameters {
            let value = effect.value(of: parameter.id, default: parameter.defaultValue, atOffset: offset)
            guard value.isFinite else {
                LabStatus.report(effect.id, error: "\(parameter.name) isn’t a valid number.")
                return nil
            }
            values[parameter.id] = value.clamped(to: parameter.range)
        }
        let context = ExperimentContext(input: input, canvas: canvas, time: time, values: values,
                                        source: effect.source ?? experiment.defaultSource)
        do {
            let output = try experiment.render(context)
            guard !output.extent.isEmpty || input == nil else {
                throw ExperimentError.message("It produced an empty picture.")
            }
            LabStatus.report(effect.id, error: nil)
            return output
        } catch {
            LabStatus.report(effect.id, error: error.localizedDescription)
            return nil
        }
    }
}
