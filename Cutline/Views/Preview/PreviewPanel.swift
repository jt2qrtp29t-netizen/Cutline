import SwiftUI

/// The composition preview, letterboxed inside the recessed surround, with a
/// floating transport bar.
struct PreviewPanel: View {
    let editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: editor.playback.player)
                .aspectRatio(editor.settings.aspectRatio, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.border)
                }
                .shadow(color: Theme.shadow, radius: 12, y: 4)
                .overlay(alignment: .top) { OfflineMediaBanner(editor: editor).padding(10) }
                .overlay(alignment: .topTrailing) { PlaybackMediaBadge(editor: editor).padding(10) }
                .overlay(alignment: .topLeading) {
                    if editor.showsUngraded {
                        Text("BEFORE · UNGRADED")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.raised.opacity(0.9), in: .capsule)
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)
            TransportBar(editor: editor, playback: editor.playback)
                .padding(.bottom, 14)
        }
        .background(Theme.recessed)
        // Clicking the preview releases text-field focus so Space plays/pauses.
        .contentShape(.rect)
        .onTapGesture { editor.endTextEditing() }
    }
}

private struct TransportBar: View {
    let editor: EditorController
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 14) {
            Text(Timecode.string(for: playback.currentTime, fps: editor.fps, alwaysShowHours: true))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(playback.isPlaying ? Theme.accent : Theme.textPrimary)
                .frame(width: 96, alignment: .leading)
                .contentTransition(.numericText())

            HStack(spacing: 2) {
                TransportButton(systemImage: "backward.end.fill", help: "Go to Start (Home)") {
                    editor.goToStart()
                }
                TransportButton(systemImage: "backward.frame.fill", help: "Previous Frame (←)") {
                    playback.step(frames: -1)
                }
                TransportButton(
                    systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                    help: "Play/Pause (Space)",
                    isProminent: true
                ) {
                    editor.togglePlayback()
                }
                TransportButton(systemImage: "forward.frame.fill", help: "Next Frame (→)") {
                    playback.step(frames: 1)
                }
                TransportButton(systemImage: "forward.end.fill", help: "Go to End (End)") {
                    editor.goToEnd()
                }
            }

            Text(Timecode.string(for: editor.state.duration, fps: editor.fps, alwaysShowHours: true))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 96, alignment: .trailing)

            Rectangle().fill(Theme.border).frame(width: 1, height: 18)
            PlaybackMediaMenu()
            MuteButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
    }
}

private struct TransportButton: View {
    let systemImage: String
    let help: String
    var isProminent = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isProminent ? 16 : 12, weight: .semibold))
                .foregroundStyle(isProminent ? Theme.accent : (isHovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: isProminent ? 36 : 28, height: 28)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

/// Chooses whether playback reads the original files or their optimized or proxy copies.
struct PlaybackMediaMenu: View {
    @Bindable private var settings = AppSettings.shared
    @State private var isHovering = false

    var body: some View {
        Menu {
            Picker("Playback Media", selection: $settings.playbackMedia) {
                ForEach(PlaybackMedia.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Text("Exports always use the original files.")
        } label: {
            Image(systemName: settings.playbackMedia == .original ? "film" : "film.stack")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(settings.playbackMedia == .original
                                 ? (isHovering ? Theme.textPrimary : Theme.textSecondary) : Theme.accent)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback Media: \(settings.playbackMedia.title)")
        .onHover { isHovering = $0 }
    }
}

/// Says when the viewer shows optimized or proxy copies instead of the originals, so
/// a softer proxy picture is never mistaken for the real thing.
private struct PlaybackMediaBadge: View {
    let editor: EditorController
    private var library: GeneratedMediaLibrary { .shared }

    var body: some View {
        let _ = library.revision
        let choice = AppSettings.shared.playbackMedia
        let used = Set(editor.state.allClips.map(\.mediaID))
        let kinds = Set(editor.state.media.filter { used.contains($0.id) }.compactMap { media in
            choice.preference.first { library.status(of: media, kind: $0) == .ready }
        })
        if !kinds.isEmpty {
            Text(kinds.contains(.proxy) ? "PROXY" : "OPTIMIZED")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.raised.opacity(0.9), in: .capsule)
                .help(kinds.contains(.proxy) ? "Playing proxy copies (half size). Exports use the original files."
                      : "Playing optimized copies. Exports use the original files.")
        }
    }
}

/// Universal mute toggle; mutes playback in every open project.
struct MuteButton: View {
    private var settings: AppSettings { .shared }
    @State private var isHovering = false

    var body: some View {
        Button {
            settings.isMuted.toggle()
        } label: {
            Image(systemName: settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(settings.isMuted ? Theme.destructive : (isHovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(settings.isMuted ? "Unmute All Audio (⇧⌘M)" : "Mute All Audio (⇧⌘M)")
        .onHover { isHovering = $0 }
    }
}

/// Warns that clips on the timeline use files that are missing, with a way to find them.
private struct OfflineMediaBanner: View {
    let editor: EditorController

    var body: some View {
        let offline = editor.offlineMedia
        if let first = offline.first {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.offlineBadge)
                Text(offline.count == 1
                     ? "“\(first.name)” is offline"
                     : "\(offline.count) media files are offline")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let animations = editor.offlineAnimations
                if !animations.isEmpty {
                    if editor.isRerenderingAnimations {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(animations.count == 1 ? "Render Again" : "Render \(animations.count) Again") { editor.rerenderAnimations() }
                            .controlSize(.small)
                            .help("Renders the missing animations again from their saved settings")
                    }
                }
                if let other = offline.first(where: { item in !animations.contains { $0.id == item.id } }) {
                    Button("Relink…") { editor.relinkMedia(other.id) }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.raised.opacity(0.95), in: .capsule)
            .overlay { Capsule().strokeBorder(Theme.offlineBadge.opacity(0.6)) }
            .help(offline.map { "\($0.name): \($0.path)" }.joined(separator: "\n")
                  + "\n\nThe files were moved, renamed or deleted, or are on a disk that isn’t connected.")
        }
    }
}
