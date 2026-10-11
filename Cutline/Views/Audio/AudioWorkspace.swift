import SwiftUI

/// The Audio tab: the mixer and the preview (the timeline runs underneath).
struct AudioWorkspace: View {
    let editor: EditorController

    @AppStorage("layout.mixerWidth") private var mixerWidth = 520.0

    var body: some View {
        HStack(spacing: 0) {
            MixerPanel(editor: editor)
                .frame(width: mixerWidth)
            PanelDivider(axis: .vertical, size: $mixerWidth, range: 300...900)
            PreviewPanel(editor: editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
