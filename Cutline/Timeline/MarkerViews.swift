import SwiftUI

/// Pennant-shaped flag drawn on the ruler.
nonisolated struct MarkerFlagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.midY * 0.9))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.8))
        path.addLine(to: CGPoint(x: rect.minX + 1.5, y: rect.maxY * 0.8))
        path.addLine(to: CGPoint(x: rect.minX + 1.5, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Markers along the ruler, positioned relative to its visible window.
struct RulerMarkers: View {
    let editor: EditorController
    let layout: TimelineLayout
    let originX: CGFloat
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(editor.state.markers) { marker in
                flag(for: marker, isDraft: false)
            }
            if let draft = editor.markerDraft {
                flag(for: draft, isDraft: true)
            }
        }
        .frame(width: width, height: Theme.Metrics.rulerHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func flag(for marker: Marker, isDraft: Bool) -> some View {
        let rawX = layout.x(for: marker.time) - originX
        // A new marker's popover needs an on-screen anchor even if the playhead is scrolled away.
        let x = isDraft ? rawX.clamped(to: 0...max(width - 12, 0)) : rawX
        if x > -40 && x < width + 40 {
            MarkerFlag(editor: editor, marker: marker, isDraft: isDraft)
                .offset(x: x)
        }
    }
}

private struct MarkerFlag: View {
    let editor: EditorController
    let marker: Marker
    let isDraft: Bool

    @State private var isHovering = false

    private var isPresented: Binding<Bool> {
        Binding(
            get: { isDraft ? editor.markerDraft?.id == marker.id : editor.editingMarkerID == marker.id },
            set: { presented in
                guard !presented else { return }
                if isDraft {
                    // Dismissing the popover by clicking elsewhere keeps the marker.
                    if let draft = editor.markerDraft, draft.id == marker.id {
                        editor.commitMarkerDraft(draft)
                    }
                } else if editor.editingMarkerID == marker.id {
                    editor.editingMarkerID = nil
                }
            }
        )
    }

    var body: some View {
        MarkerFlagShape()
            .fill(Theme.marker(marker.color))
            .overlay { MarkerFlagShape().stroke(Theme.playheadOutline.opacity(0.6), lineWidth: 0.5) }
            .frame(width: 11, height: Theme.Metrics.rulerHeight - 6)
            .scaleEffect(isHovering ? 1.12 : 1, anchor: .bottomLeading)
            .padding(.top, 2)
            .contentShape(.rect.inset(by: -3))
            .help(marker.name)
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.15), value: isHovering)
            .onTapGesture(count: 2) { editor.editingMarkerID = marker.id }
            .onTapGesture { editor.jump(to: marker) }
            .contextMenu {
                if !isDraft {
                    Button("Edit Marker…") { editor.editingMarkerID = marker.id }
                    Button("Delete Marker", role: .destructive) { editor.deleteMarker(marker.id) }
                }
            }
            .popover(isPresented: isPresented, arrowEdge: .bottom) {
                MarkerEditor(editor: editor, marker: marker, isNew: isDraft) {
                    editor.editingMarkerID = nil
                }
            }
    }
}

/// Name + color editor shown in a popover, both for new and existing markers.
struct MarkerEditor: View {
    let editor: EditorController
    let isNew: Bool
    /// Closes the hosting popover (existing markers only; drafts close themselves).
    let onClose: () -> Void

    @State private var name: String
    @State private var color: MarkerColor
    @FocusState private var nameFocused: Bool
    private let original: Marker

    init(editor: EditorController, marker: Marker, isNew: Bool, onClose: @escaping () -> Void = {}) {
        self.editor = editor
        self.isNew = isNew
        self.onClose = onClose
        self.original = marker
        _name = State(initialValue: marker.name)
        _color = State(initialValue: marker.color)
    }

    private var edited: Marker {
        var marker = original
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        marker.name = trimmed.isEmpty ? original.name : trimmed
        marker.color = color
        return marker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isNew ? "New Marker" : "Edit Marker")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(Timecode.string(for: original.time, fps: editor.fps))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }

            TextField("Marker name", text: $name)
                .themedField()
                .focused($nameFocused)
                .onSubmit(done)

            HStack(spacing: 7) {
                ForEach(MarkerColor.allCases) { option in
                    Button {
                        color = option
                    } label: {
                        Circle()
                            .fill(Theme.marker(option))
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle()
                                    .strokeBorder(Theme.textPrimary, lineWidth: color == option ? 2 : 0)
                                    .padding(-3)
                            }
                            .padding(3)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(option.displayName)
                }
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        onClose()
                        editor.deleteMarker(original.id)
                    }
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 270)
        .onAppear {
            // Popovers take focus a beat after they appear.
            Task { @MainActor in nameFocused = true }
        }
    }

    private func done() {
        if isNew {
            editor.commitMarkerDraft(edited)
        } else {
            if edited != original { editor.updateMarker(edited) }
            onClose()
        }
    }

    private func cancel() {
        if isNew {
            editor.cancelMarkerDraft()
        } else {
            onClose()
        }
    }
}
