import SwiftUI

/// The editor's own title bar: project name in the center, room for the window
/// buttons on the left, and quick actions. Drag it to move the window and
/// double-click it to zoom, like a standard title bar.
struct EditorTitleBar: View {
    let editor: EditorController
    let title: String

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                Color.clear.frame(width: Theme.Metrics.trafficLightInset)
                IconButton(systemImage: "square.and.arrow.down", help: "Import Media… (⌘I)") {
                    editor.showImportPanel()
                }
                IconButton(systemImage: "scissors", help: "Blade at Playhead (⌘B)") {
                    editor.bladeAtPlayhead()
                }
                IconButton(systemImage: "bookmark", help: "Add Marker (⌘M)") {
                    editor.addMarkerAtPlayhead()
                }
                IconButton(systemImage: "textformat", help: "Add Text (⇧⌘T)") {
                    editor.addTextClip()
                }
                Spacer()
                Text(AppVersion.display)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.raised, in: .capsule)
                    .help("Cutline \(AppVersion.display) (build \(AppVersion.build))")
            }

            HStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(editor.settings.resolutionLabel) · \(editor.settings.frameRate) fps")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .allowsHitTesting(false)
        }
        .padding(.trailing, 10)
        .frame(height: Theme.Metrics.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background {
            Theme.background
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}
