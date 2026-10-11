import AppKit
import SwiftUI

/// The Export tab's thumbnail maker: the thumbnail as it will be saved, three candidates
/// to choose from (with why each was picked), an optional title and saving.
struct ThumbnailStudio: View {
    let editor: EditorController
    let session: ThumbnailSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            switch session.phase {
            case .finding:
                working("Looking through the video for good frames…", progress: session.progress)
            case let .asking(model):
                working(model.map { "Asking \($0) to choose (on this Mac). The first time, loading the model can take a few minutes…" }
                        ?? "Choosing the best frames…", progress: nil)
            case let .failed(message):
                VStack(spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.sandbox)
                    Button("Try Again") { session.start() }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                ScrollView { ThumbnailStudioContent(session: session).padding(16) }
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            SectionLabel("Thumbnail")
            Text(session.movie.lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer()
            if session.phase == .ready {
                Button("Choose Again") { session.start() }
                    .controlSize(.small)
                    .help("Looks through the video and asks again")
            }
            Button {
                session.cancel()
                editor.thumbnail = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Close the thumbnail maker")
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private func working(_ text: String, progress: Double?) -> some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress).frame(width: 260)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Cancel") {
                session.cancel()
                editor.thumbnail = nil
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The thumbnail, the three candidates, the title and saving.
struct ThumbnailStudioContent: View {
    let session: ThumbnailSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let image = session.render() {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: 420)
            }
            Group {
                if let model = session.model {
                    Label("Chosen by \(model), on this Mac.", systemImage: "sparkles")
                } else {
                    Label(session.note.map { "Chosen by picture quality alone. \($0)" } ?? "Chosen by picture quality.",
                          systemImage: "eye")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(session.picks.enumerated()), id: \.element.id) { index, pick in
                    CandidateCard(pick: pick, isSelected: index == session.selected) { session.selected = index }
                }
            }

            InspectorSection(title: "Title") {
                Toggle("Add a title", isOn: Binding(get: { session.showsTitle }, set: { session.showsTitle = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                if session.showsTitle {
                    TextField("Title", text: Binding(get: { session.title }, set: { session.title = $0 }))
                        .themedField()
                        .font(.system(size: 12))
                    Picker("Style", selection: Binding(get: { session.preset }, set: { session.preset = $0 })) {
                        ForEach(CaptionPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            HStack(spacing: 8) {
                Picker("Format", selection: Binding(get: { session.format }, set: { session.format = $0 })) {
                    ForEach(ThumbnailComposer.Format.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                Button("Save Thumbnail") { session.save() }
                    .keyboardShortcut(.defaultAction)
                if let saved = session.savedURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
                Spacer()
            }
            .controlSize(.small)
            if let message = session.saveMessage {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct CandidateCard: View {
    /// Minutes and seconds into the movie ("1:23.4").
    static func clock(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    let pick: ThumbnailPicks.Pick
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                // A 16:9 box as wide as the card's share of the row; the frame fills it.
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Image(decorative: pick.candidate.image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(.rect(cornerRadius: 6))
                Text(pick.reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.clock(pick.candidate.time))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(isSelected ? Theme.accentMuted : Theme.raised.opacity(0.5), in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
