import SwiftUI

/// The Audio tab: the mixer, the preview and the selected track's settings and effects
/// (the timeline runs underneath). In a narrow window the side columns shrink so all
/// three always fit.
struct AudioWorkspace: View {
    let editor: EditorController

    @AppStorage("layout.mixerWidth") private var mixerWidth = 460.0
    @AppStorage("layout.audioTrackPanelWidth") private var panelWidth = 340.0

    var body: some View {
        GeometryReader { geometry in
            let fitted = AudioWorkspaceLayout.fit(mixer: mixerWidth, panel: panelWidth, available: geometry.size.width)
            HStack(spacing: 0) {
                MixerPanel(editor: editor)
                    .frame(width: fitted.mixer)
                PanelDivider(axis: .vertical, size: $mixerWidth, range: AudioWorkspaceLayout.mixerRange)
                PreviewPanel(editor: editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PanelDivider(axis: .vertical, size: $panelWidth, range: AudioWorkspaceLayout.panelRange, direction: -1)
                AudioTrackPanel(editor: editor)
                    .frame(width: fitted.panel)
            }
        }
    }
}

/// How the Audio tab's columns share the window.
nonisolated enum AudioWorkspaceLayout {
    static let mixerRange = 220.0...900.0
    static let panelRange = 260.0...520.0
    /// The preview keeps at least this much; the side columns give way first.
    static let minimumPreview = 240.0
    /// The two dividers.
    static let dividers = 12.0

    /// The mixer's and panel's widths: as the person set them when they fit, otherwise
    /// shrunk in proportion (not below their minimums) so the preview keeps its share.
    static func fit(mixer: Double, panel: Double, available: Double) -> (mixer: Double, panel: Double) {
        let mixer = min(max(mixer, mixerRange.lowerBound), mixerRange.upperBound)
        let panel = min(max(panel, panelRange.lowerBound), panelRange.upperBound)
        let budget = available - dividers - minimumPreview
        guard mixer + panel > budget else { return (mixer, panel) }
        let minimums = mixerRange.lowerBound + panelRange.lowerBound
        guard budget > minimums else { return (mixerRange.lowerBound, panelRange.lowerBound) }
        // Share the room above the minimums in the same proportion as the chosen extras.
        let extraMixer = mixer - mixerRange.lowerBound, extraPanel = panel - panelRange.lowerBound
        let share = (budget - minimums) / max(extraMixer + extraPanel, 1)
        return (mixerRange.lowerBound + extraMixer * share, panelRange.lowerBound + extraPanel * share)
    }
}
