import SwiftUI

/// Keeps an editor's player and selections in step with its project. Used by the
/// project window for the main editor and by the Playground for its own.
struct EditorSync: ViewModifier {
    let editor: EditorController

    func body(content: Content) -> some View {
        content
            .onAppear {
                editor.playback.update(with: editor.state, isLiveEdit: false)
            }
            .onChange(of: editor.store.state) { _, state in
                // Drop selections that no longer exist or became locked (after undo, delete, etc.).
                let ids = editor.selectableClipIDs
                if !editor.selection.isSubset(of: ids) { editor.selection.formIntersection(ids) }
                editor.playback.update(with: state, isLiveEdit: editor.store.isLiveEditing)
                editor.pruneKeyframeSelection()
            }
            .onChange(of: editor.selection) { editor.pruneKeyframeSelection() }
            .onChange(of: editor.store.isLiveEditing) { _, isLive in
                if !isLive { editor.playback.update(with: editor.state, isLiveEdit: false) }
            }
            .onChange(of: AppSettings.shared.isMuted, initial: true) { _, muted in
                editor.playback.setMuted(muted)
            }
            .sheet(item: Binding(get: { editor.clipDialog }, set: { editor.clipDialog = $0 })) { dialog in
                ClipDialogView(editor: editor, dialog: dialog)
            }
            .alert(item: Binding(get: { editor.alert }, set: { editor.alert = $0 })) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
    }
}

extension View {
    func editorSync(_ editor: EditorController) -> some View {
        modifier(EditorSync(editor: editor))
    }
}
