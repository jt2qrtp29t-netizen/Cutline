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
            MuteButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
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
