import SwiftUI

/// Left-hand Adjustments panel. Each section is an independent view; to add one,
/// add another section to the stack in `body`.
struct InspectorPanel: View {
    let editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(selectedText == nil ? "Adjustments" : "Text Adjustments")
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let (clip, text) = selectedText {
                        // A selected text clip gets its own panel.
                        TextInspector(editor: editor, clip: clip, text: text)
                            .id(clip.id)
                    } else {
                        if let transition = editor.selectedTransition {
                            SelectedTransitionSection(editor: editor, id: transition)
                        }
                        selectionSection
                        MarkersInspector(editor: editor)
                        ProjectInspectorSection(settings: editor.settings, mediaCount: editor.state.media.count)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.background)
    }

    /// The selected clip, if exactly one is selected and it's a text clip.
    private var selectedText: (Clip, TextStyle)? {
        let selected = editor.selectedClips
        guard selected.count == 1, let clip = selected.first, let text = clip.text else { return nil }
        return (clip, text)
    }

    @ViewBuilder
    private var selectionSection: some View {
        let selected = editor.selectedClips
        if selected.count == 1, let clip = selected.first,
           let track = editor.state.track(ofClip: clip.id) {
            ClipInspector(editor: editor, clip: clip, kind: track.kind)
                .id(clip.id)
        } else {
            InspectorSection(title: "Clip") {
                HStack(spacing: 8) {
                    Image(systemName: selected.isEmpty ? "cursorarrow.click" : "square.stack")
                        .foregroundStyle(Theme.textTertiary)
                    Text(selected.isEmpty ? "Select a clip to edit its properties." : "\(selected.count) clips selected")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ProjectInspectorSection: View {
    let settings: ProjectSettings
    let mediaCount: Int

    var body: some View {
        InspectorSection(title: "Project") {
            InspectorValueRow(title: "Name", value: settings.name)
            InspectorValueRow(title: "Resolution", value: "\(settings.width) × \(settings.height)")
            InspectorValueRow(title: "Frame rate", value: "\(settings.frameRate) fps")
            InspectorValueRow(title: "Media", value: "\(mediaCount) item\(mediaCount == 1 ? "" : "s")")
        }
    }
}
