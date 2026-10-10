import SwiftUI

/// Menu bar commands. Items depend only on whether an editor is focused: the menu
/// bar doesn't re-evaluate when the selection changes, so selection-based enabling
/// would go stale (and a disabled item ignores its shortcut). Commands that don't
/// apply to the current selection beep instead.
struct CutlineCommands: Commands {
    @FocusedValue(\.editor) private var editor
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { openWindow(id: WindowID.launch) }
                .keyboardShortcut("n")
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Media…") { editor?.showImportPanel() }
                .keyboardShortcut("i")
                .disabled(editor == nil)
        }

        CommandGroup(replacing: .importExport) {
            Button("Export…") { editor?.showExportPlaceholder() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { editor?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(editor == nil)
            Button("Zoom Out") { editor?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(editor == nil)
            Divider()
        }

        CommandMenu("Clip") {
            Button("Blade at Playhead") { editor?.bladeAtPlayhead() }
                .keyboardShortcut("b")
                .disabled(editor == nil)
            Button("Delete") {
                if TextInputForwarding.forward(#selector(NSResponder.deleteBackward(_:))) { return }
                editor?.deleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(editor == nil)

            Divider()

            Button("Link / Unlink Clips") { editor?.toggleLinkSelection() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Lock / Unlock Clips") { editor?.toggleLockSelection() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Speed…") { editor?.showClipDialogForSelection(.speed) }
                .disabled(editor == nil)
            Button("Duration…") { editor?.showClipDialogForSelection(.duration) }
                .disabled(editor == nil)

            Divider()

            Toggle("Snapping", isOn: Binding(
                get: { editor?.snappingEnabled ?? false },
                set: { editor?.snappingEnabled = $0 }
            ))
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(editor == nil)
            Button("Add Text") { editor?.addTextClip() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Add Video Track") { editor?.addTrack(.video) }
                .disabled(editor == nil)
            Button("Add Audio Track") { editor?.addTrack(.audio) }
                .disabled(editor == nil)
            Button("Add Text Track") { editor?.addTrack(.text) }
                .disabled(editor == nil)
        }

        CommandMenu("Marker") {
            Button("Add Marker…") { editor?.addMarkerAtPlayhead() }
                .keyboardShortcut("m")
                .disabled(editor == nil)
            Divider()
            Button("Previous Marker") { editor?.goToMarker(next: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Next Marker") { editor?.goToMarker(next: true) }
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
                editor?.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(editor == nil)

            Toggle("Mute All Audio", isOn: Binding(
                get: { AppSettings.shared.isMuted },
                set: { AppSettings.shared.isMuted = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Divider()

            Button("Go to Start") { editor?.goToStart() }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(editor == nil)
            Button("Go to End") { editor?.goToEnd() }
                .keyboardShortcut(.end, modifiers: [])
                .disabled(editor == nil)
            Button("Previous Frame") {
                if TextInputForwarding.forward(#selector(NSResponder.moveLeft(_:))) { return }
                editor?.playback.step(frames: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(editor == nil)
            Button("Next Frame") {
                if TextInputForwarding.forward(#selector(NSResponder.moveRight(_:))) { return }
                editor?.playback.step(frames: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(editor == nil)
        }
    }
}
