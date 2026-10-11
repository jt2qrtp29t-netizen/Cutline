import Foundation

/// A thread of its own for reading or writing media. AVFoundation's sample providers
/// wait for each sample synchronously, so on Swift's shared threads (one per core) a
/// few readers at once could block all of them, including threads the samples they're
/// waiting for need. A dedicated serial queue can wait without starving anything.
///
/// Use with `Task(executorPreference:)` or `withTaskExecutorPreference(_:operation:)`.
nonisolated final class MediaWorkThread: TaskExecutor {
    private let queue: DispatchQueue

    init(label: String = "app.cutline.media-work") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}
