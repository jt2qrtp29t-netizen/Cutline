import SwiftUI

/// The frames being exported, live, in place of the preview while an export runs.
struct ExportLiveView: View {
    let job: ExportJob
    let aspectRatio: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.videoBlack
                if let frame = job.liveFrame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.border) }
            .shadow(color: Theme.shadow, radius: 12, y: 4)
            .overlay(alignment: .topLeading) { liveBadge.padding(10) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            status
                .padding(.bottom, 14)
        }
        .background(Theme.recessed)
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.destructive).frame(width: 7, height: 7)
            Text(job.isCanceling ? "CANCELING" : job.phase.title.uppercased())
                .font(.system(size: 10, weight: .bold))
            Text(job.title)
                .font(.system(size: 10.5))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.raised.opacity(0.9), in: .capsule)
        .allowsHitTesting(false)
    }

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let snapshot = job.snapshot
            let fps = snapshot.frameRate
            let frameTime = snapshot.range.start + Time(ticks: Time.frame(fps: fps).ticks * Int64(job.liveFrameIndex))
            HStack(spacing: 14) {
                Group {
                    if job.phase == .rendering || job.phase == .mixingAudio {
                        Text("Frame \(job.liveFrameIndex + 1) of \(job.totalFrames)")
                    } else {
                        Text(ExportJobRow.detail(of: job).components(separatedBy: " · ").last ?? "")
                    }
                }
                .frame(minWidth: 130, alignment: .leading)
                Text(Timecode.string(for: frameTime, fps: fps, alwaysShowHours: true))
                    .foregroundStyle(Theme.accent)
                ProgressView(value: job.progress)
                    .tint(Theme.accent)
                    .frame(width: 160)
                Text(job.remaining(at: context.date).map { ExportSettingsPanel.duration($0) + " left" } ?? "Starting…")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 110, alignment: .leading)
                Rectangle().fill(Theme.border).frame(width: 1, height: 18)
                Button {
                    AppSettings.shared.showFramesWhileExporting = false
                } label: {
                    Image(systemName: "eye.slash")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Hide Frames While Exporting (exports a little faster)")
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

/// Over the preview while an export runs with frames hidden: progress, and a way to show them.
struct ExportHiddenFramesBadge: View {
    let job: ExportJob

    var body: some View {
        Button {
            AppSettings.shared.showFramesWhileExporting = true
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Theme.destructive).frame(width: 7, height: 7)
                Text("Rendering \(Int(job.progress * 100))% · Show Frames")
            }
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.raised.opacity(0.9), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Show the frames being exported, live")
    }
}
