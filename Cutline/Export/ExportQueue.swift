import AppKit
import Observation
import UserNotifications

/// One export in the queue.
@Observable
final class ExportJob: Identifiable {
    enum Status: Equatable {
        case queued, rendering, done, failed(String), canceled

        var title: String {
            switch self {
            case .queued: "Queued"
            case .rendering: "Rendering"
            case .done: "Done"
            case .failed: "Failed"
            case .canceled: "Canceled"
            }
        }
        var isFinished: Bool { self != .queued && self != .rendering }
    }

    let id = UUID()
    let title: String
    /// "Edit" or "Playground".
    let sourceName: String
    let isPlayground: Bool
    let snapshot: ExportSnapshot
    let destination: URL

    var status = Status.queued
    /// 0...1.
    var progress = 0.0
    var framesDone = 0
    var startDate: Date?
    var endDate: Date?
    var warnings: [String] = []
    /// The latest frame shown while rendering (scaled down), and its index in the export.
    var liveFrame: CGImage?
    var liveFrameIndex = 0
    /// What the running export is doing.
    var phase = ExportPhase.mixingAudio
    /// Cancel was pressed; the export is stopping and cleaning up.
    var isCanceling = false

    @ObservationIgnored let cancellation = ExportCancellation()
    /// The project to add the finished file to with "Add to Media".
    @ObservationIgnored weak var project: EditorController?

    var totalFrames: Int { snapshot.frameCount }

    init(title: String, sourceName: String, isPlayground: Bool, snapshot: ExportSnapshot, destination: URL,
         project: EditorController? = nil) {
        self.title = title
        self.sourceName = sourceName
        self.isPlayground = isPlayground
        self.snapshot = snapshot
        self.destination = destination
        self.project = project
    }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let startDate else { return 0 }
        return (endDate ?? now).timeIntervalSince(startDate)
    }

    /// Estimated seconds left, once there's enough progress to judge.
    func remaining(at now: Date = Date()) -> TimeInterval? {
        guard status == .rendering, progress > 0.03 else { return nil }
        let elapsed = elapsed(at: now)
        return elapsed / progress * (1 - progress)
    }
}

/// Exports run one at a time, in the order they were added, in the background.
@Observable
final class ExportQueue {
    static let shared = ExportQueue()

    private(set) var jobs: [ExportJob] = []
    /// Whether to post a notification when an export finishes (off in tests).
    @ObservationIgnored var notifies = !isRunningTests

    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var sleepLock: (any NSObjectProtocol)?

    var current: ExportJob? { jobs.first { $0.status == .rendering } }
    var hasActiveJobs: Bool { jobs.contains { !$0.status.isFinished } }

    func enqueue(_ job: ExportJob) {
        jobs.append(job)
        startIfNeeded()
    }

    /// Cancels a queued or running export. A running one stops and its partial file is removed.
    func cancel(_ job: ExportJob) {
        switch job.status {
        case .queued:
            job.status = .canceled
            job.endDate = Date()
        case .rendering:
            job.isCanceling = true
            job.cancellation.cancel()
        default:
            break
        }
    }

    func remove(_ job: ExportJob) {
        guard job.status.isFinished else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }

    /// Cancels everything and waits until the running export has cleaned up.
    func cancelAllAndWait() async {
        for job in jobs { cancel(job) }
        await worker?.value
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.work()
        }
    }

    private func work() async {
        // Keep the Mac awake (the screen may still sleep) while exporting.
        sleepLock = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                          reason: "Exporting video")
        while let job = jobs.first(where: { $0.status == .queued }) {
            await run(job)
        }
        if let sleepLock { ProcessInfo.processInfo.endActivity(sleepLock) }
        sleepLock = nil
        worker = nil
    }

    private func run(_ job: ExportJob) async {
        job.status = .rendering
        job.startDate = Date()
        do {
            // Frames for the live view, when it's on (otherwise nothing is captured).
            let (width, height) = job.snapshot.settings.resolution.size(for: job.snapshot.state.settings)
            let tap = AppSettings.shared.showFramesWhileExporting
                ? ExportFrameTap(outputSize: CGSize(width: width, height: height), fills: job.snapshot.settings.fit == .fill) { image, index in
                Task { @MainActor in
                    guard job.status == .rendering || index == job.totalFrames - 1 else { return }
                    job.liveFrame = image
                    job.liveFrameIndex = index
                }
            } : nil
            let result = try await ExportRunner.run(job.snapshot, to: job.destination, cancellation: job.cancellation,
                                                    frameTap: tap, phase: { phase in
                Task { @MainActor in
                    guard job.status == .rendering else { return }
                    job.phase = phase
                }
            }) { progress, frames in
                Task { @MainActor in
                    guard job.status == .rendering else { return }
                    job.progress = max(job.progress, progress)
                    job.framesDone = max(job.framesDone, frames)
                }
            }
            job.progress = 1
            job.framesDone = result.frames
            job.warnings = result.warnings
            job.status = .done
            // Learn how fast exports run on this Mac, for the next estimate.
            if let start = job.startDate {
                let snapshot = job.snapshot
                let (w, h) = snapshot.settings.resolution.size(for: snapshot.state.settings)
                let encoder = ExportTimeEstimate.Encoder(snapshot.settings)
                let predicted = ExportTimeEstimate.predicted(
                    frames: result.frames, width: w, height: h, project: snapshot.state.settings, encoder: encoder,
                    complexity: ExportTimeEstimate.complexity(of: snapshot.state, in: snapshot.range))
                    + ExportTimeEstimate.networkOptimizationSeconds(snapshot.settings, frames: result.frames, project: snapshot.state.settings)
                ExportTimeEstimate.learn(encoder: encoder, predicted: predicted, actual: Date().timeIntervalSince(start))
            }
        } catch ExportError.cancelled {
            job.status = .canceled
        } catch {
            job.status = .failed(error.localizedDescription)
        }
        job.endDate = Date()
        if notifies { notify(job) }
    }

    private func notify(_ job: ExportJob) {
        let content = UNMutableNotificationContent()
        switch job.status {
        case .done:
            content.title = "Export finished"
            content.body = job.warnings.isEmpty ? "“\(job.destination.lastPathComponent)” is ready."
                : "“\(job.destination.lastPathComponent)” is ready, with \(job.warnings.count) warning\(job.warnings.count == 1 ? "" : "s")."
        case .failed(let message):
            content.title = "Export failed"
            content.body = message
        default:
            return
        }
        let center = UNUserNotificationCenter.current()
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(request)
        }
    }
}
