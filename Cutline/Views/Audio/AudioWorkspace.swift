import SwiftUI

/// The Audio tab: the mixer, the preview and the selected track's settings and effects
/// (the timeline runs underneath).
struct AudioWorkspace: View {
    let editor: EditorController

    @AppStorage("layout.mixerWidth") private var mixerWidth = 460.0
    @AppStorage("layout.audioTrackPanelWidth") private var panelWidth = 340.0

    var body: some View {
        HStack(spacing: 0) {
            MixerPanel(editor: editor)
                .frame(width: mixerWidth)
            PanelDivider(axis: .vertical, size: $mixerWidth, range: 280...900)
            PreviewPanel(editor: editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider(axis: .vertical, size: $panelWidth, range: 300...520, direction: -1)
            AudioTrackPanel(editor: editor)
                .frame(width: panelWidth)
        }
    }
}
