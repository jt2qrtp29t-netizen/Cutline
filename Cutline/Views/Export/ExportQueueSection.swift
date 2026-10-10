import SwiftUI

/// The export queue: progress and results of every export in this session.
struct ExportQueueSection: View {
    private var queue: ExportQueue { ExportQueue.shared }

    var body: some View {
        InspectorSection(title: "Queue") {
            if queue.jobs.isEmpty {
                Text("Exports appear here while they render, then stay so you can open them.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        ForEach(queue.jobs.reversed()) { job in
                            ExportJobRow(job: job, now: context.date)
                        }
                    }
                }
                if queue.jobs.contains(where: \.status.isFinished) {
                    Button("Clear Finished") { queue.clearFinished() }
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct ExportJobRow: View {
    let job: ExportJob
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(job.destination.lastPathComponent)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.isPlayground {
                    Text("SANDBOX")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.sandbox)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.sandboxMuted, in: .capsule)
                }
                Spacer()
                Text(job.status.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint)
            }
            switch job.status {
            case .queued:
                Text("Waiting for the export before it.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            case .rendering:
                ProgressView(value: job.progress)
                    .tint(job.isPlayground ? Theme.sandbox : Theme.accent)
                HStack {
                    Text("\(Int(job.progress * 100))% · frame \(job.framesDone) of \(job.totalFrames)")
                    Spacer()
                    Text(timing)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.offlineBadge)
                    .fixedSize(horizontal: false, vertical: true)
            case .done, .canceled:
                if job.status == .done {
                    Text("\(job.totalFrames) frames in \(ExportSettingsPanel.duration(job.elapsed(at: now)).replacingOccurrences(of: "about ", with: ""))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            ForEach(job.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.sandbox)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                switch job.status {
                case .queued, .rendering:
                    Button("Cancel") { ExportQueue.shared.cancel(job) }
                case .done:
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.destination]) }
                    Button("Open") { NSWorkspace.shared.open(job.destination) }
                    if let project = job.project {
                        Button("Add to Media") { project.importMedia([job.destination]) }
                    }
                default:
                    Button("Remove") { ExportQueue.shared.remove(job) }
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 6))
    }

    private var timing: String {
        let elapsed = Self.clock(job.elapsed(at: now))
        guard let remaining = job.remaining(at: now) else { return "\(elapsed) elapsed" }
        return "\(elapsed) elapsed · \(Self.clock(remaining)) left"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var icon: String {
        switch job.status {
        case .queued: "clock"
        case .rendering: "gearshape.2"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .canceled: "minus.circle"
        }
    }

    private var tint: Color {
        switch job.status {
        case .done: Theme.accent
        case .failed: Theme.offlineBadge
        case .rendering: Theme.textPrimary
        default: Theme.textTertiary
        }
    }
}
