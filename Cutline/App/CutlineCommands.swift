import SwiftUI

/// Menu bar commands. Items depend only on whether an editor is focused: the menu
/// bar doesn't re-evaluate when the selection changes, so selection-based enabling
/// would go stale (and a disabled item ignores its shortcut). Commands that don't
/// apply to the current selection beep instead.
struct CutlineCommands: Commands {
    @FocusedValue(\.editor) private var editor
    @Environment(\.openWindow) private var openWindow

    /// What commands act on: the Playground's editor while its tab is showing.
    private var target: EditorController? { editor?.activeEditor }

    var body: some Commands {
        // Undo and redo follow the active editor, so the Playground has its own history.
        CommandGroup(replacing: .undoRedo) {
            let undoManager = target?.store.undoManager
            let _ = target?.store.undoRevision
            Button(undoManager?.canUndo == true ? undoManager!.undoMenuItemTitle : "Undo") { undo(redo: false) }
                .keyboardShortcut("z")
            Button(undoManager?.canRedo == true ? undoManager!.redoMenuItemTitle : "Redo") { undo(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        // The standard Settings item, named Parameters here.
        CommandGroup(replacing: .appSettings) {
            ParametersMenuItem()
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: WindowID.shortcuts) }
                .keyboardShortcut("/")
            Button("Changelog") { openWindow(id: WindowID.changelog) }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Project…") { openWindow(id: WindowID.launch) }
                .keyboardShortcut("n")
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Media…") { target?.showImportPanel() }
                .keyboardShortcut("i")
                .disabled(editor == nil)
        }

        CommandGroup(replacing: .importExport) {
            Button("Export…") { target?.showExportPlaceholder() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }

        CommandGroup(before: .toolbar) {
            ForEach(Array(Workspace.allCases.enumerated()), id: \.element) { index, workspace in
                Button(workspace.title) { editor?.workspace = workspace }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(editor == nil)
            }
            Divider()
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { target?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(editor == nil)
            Button("Zoom Out") { target?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(editor == nil)
            Divider()
        }

        CommandMenu("Clip") {
            Button("Blade at Playhead") { target?.bladeAtPlayhead() }
                .keyboardShortcut("b")
                .disabled(editor == nil)
            Button("Delete") {
                if TextInputForwarding.forward(#selector(NSResponder.deleteBackward(_:))) { return }
                target?.deleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(editor == nil)

            Divider()

            Button("Link / Unlink Clips") { target?.toggleLinkSelection() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Lock / Unlock Clips") { target?.toggleLockSelection() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Copy Grade") { target?.copyGrade() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Paste Grade") { target?.pasteGrade() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Speed…") { target?.showClipDialogForSelection(.speed) }
                .disabled(editor == nil)
            Button("Duration…") { target?.showClipDialogForSelection(.duration) }
                .disabled(editor == nil)

            Divider()

            Toggle("Snapping", isOn: Binding(
                get: { target?.snappingEnabled ?? false },
                set: { target?.snappingEnabled = $0 }
            ))
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(editor == nil)
            Button("Add Text") { target?.addTextClip() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Add Video Track") { target?.addTrack(.video) }
                .disabled(editor == nil)
            Button("Add Audio Track") { target?.addTrack(.audio) }
                .disabled(editor == nil)
            Button("Add Text Track") { target?.addTrack(.text) }
                .disabled(editor == nil)
        }

        CommandMenu("Marker") {
            Button("Add Marker…") { target?.addMarkerAtPlayhead() }
                .keyboardShortcut("m")
                .disabled(editor == nil)
            Divider()
            Button("Previous Marker") { target?.goToMarker(next: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Next Marker") { target?.goToMarker(next: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(editor == nil)
        }

        // ⌘M is "Add Marker" here, so Minimize moves to ⌥⌘M.
        CommandGroup(replacing: .windowSize) {
            Button("Minimize") { NSApp.keyWindow?.performMiniaturize(nil) }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Zoom") { NSApp.keyWindow?.performZoom(nil) }
        }

        CommandMenu("Playback") {
            Button("Play/Pause") {
                if TextInputForwarding.forwardSpace() { return }
                target?.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(editor == nil)

            Toggle("Mute All Audio", isOn: Binding(
                get: { AppSettings.shared.isMuted },
                set: { AppSettings.shared.isMuted = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Divider()

            Button("Go to Start") { target?.goToStart() }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(editor == nil)
            Button("Go to End") { target?.goToEnd() }
                .keyboardShortcut(.end, modifiers: [])
                .disabled(editor == nil)
            Button("Previous Frame") {
                if TextInputForwarding.forward(#selector(NSResponder.moveLeft(_:))) { return }
                target?.playback.step(frames: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(editor == nil)
            Button("Next Frame") {
                if TextInputForwarding.forward(#selector(NSResponder.moveRight(_:))) { return }
                target?.playback.step(frames: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(editor == nil)
        }
    }

    /// Text being edited undoes its typing; otherwise the active editor's history.
    private func undo(redo: Bool) {
        let action = Selector(redo ? "redo:" : "undo:")
        guard let undoManager = target?.store.undoManager, !(NSApp.keyWindow?.firstResponder is NSText) else {
            NSApp.sendAction(action, to: nil, from: nil)
            return
        }
        if redo ? undoManager.canRedo : undoManager.canUndo {
            redo ? undoManager.redo() : undoManager.undo()
        } else {
            NSSound.beep()
        }
    }
}

/// Opens the Parameters (settings) window with ⌘,.
private struct ParametersMenuItem: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Parameters…") { openSettings() }
            .keyboardShortcut(",")
    }
}
