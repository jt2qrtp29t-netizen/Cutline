import SwiftUI

/// List of markers: click to jump, edit or delete from the row.
struct MarkersInspector: View {
    let editor: EditorController

    var body: some View {
        InspectorSection(title: "Markers") {
            if editor.state.markers.isEmpty {
                Text("Press ⌘M to add a marker at the playhead.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 2) {
                    ForEach(editor.state.markers) { marker in
                        MarkerRow(editor: editor, marker: marker)
                    }
                }
            }
        }
    }
}

/// One marker. The name/time area is a button that jumps to the marker; Edit and
/// Delete are separate buttons that are always present (dimmed until hovered), so
/// they never compete with the row's own click handling or shift under the pointer.
private struct MarkerRow: View {
    let editor: EditorController
    let marker: Marker

    @State private var isHovering = false
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                editor.jump(to: marker)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.marker(marker.color))
                        .frame(width: 9, height: 9)
                    Text(marker.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Timecode.string(for: marker.time, fps: editor.fps))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.leading, 6)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Go to \(marker.name)")

            IconButton(systemImage: "pencil", help: "Edit Marker", size: 20) { isEditing = true }
                .opacity(isHovering || isEditing ? 1 : 0.35)
                .popover(isPresented: $isEditing, arrowEdge: .trailing) {
                    MarkerEditor(editor: editor, marker: marker, isNew: false) { isEditing = false }
                }
            IconButton(systemImage: "trash", help: "Delete Marker", size: 20) {
                isEditing = false
                editor.deleteMarker(marker.id)
            }
            .opacity(isHovering ? 1 : 0.35)
        }
        .padding(.trailing, 2)
        .frame(height: 24)
        .background(isHovering ? Theme.raisedHover : Theme.raised.opacity(0), in: .rect(cornerRadius: 5))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Go to Marker") { editor.jump(to: marker) }
            Button("Edit Marker…") { isEditing = true }
            Divider()
            Button("Delete Marker", role: .destructive) { editor.deleteMarker(marker.id) }
        }
    }
}
