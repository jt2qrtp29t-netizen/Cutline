import SwiftUI

/// Transition tiles for the Effects tab. Drag one onto a cut on the timeline, or
/// click it to use the cut nearest the playhead.
struct TransitionsSection: View {
    let editor: EditorController

    @State private var duration = 1.0
    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 6)]

    var body: some View {
        InspectorSection(title: "Transitions") {
            InspectorSlider(title: "Length", value: duration, range: 0.1...3, unit: "s", fractionDigits: 2,
                            unitsPerPoint: 0.01, onBegin: {}, onChange: { setDuration($0) }, onEnd: {},
                            onSet: { setDuration($0) })

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(TransitionKind.allCases) { kind in
                    TransitionTile(kind: kind) {
                        editor.applyTransitionAtPlayhead(kind)
                    }
                    .onDrag {
                        editor.draggedTransition = kind
                        let provider = NSItemProvider()
                        provider.register(TransitionDragItem(kind: kind))
                        return provider
                    }
                }
            }

            Text("Drag a transition onto a cut between two touching clips, or onto the start or end of a clip to transition from or to black. Click one to use the cut or edge nearest the playhead.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { duration = editor.transitionDuration }
        .onChange(of: AppSettings.shared.transitionLength) { _, length in duration = length }
    }

    private func setDuration(_ value: Double) {
        duration = value
        editor.transitionDuration = value
    }
}

private struct TransitionTile: View {
    let kind: TransitionKind
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 13, weight: .medium))
                Text(kind.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(isHovering ? Theme.raisedHover : Theme.raised, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(kind.title): drag onto a cut")
        .onHover { isHovering = $0 }
    }
}

/// Settings of the selected transition: its kind and length.
struct SelectedTransitionSection: View {
    let editor: EditorController
    let id: UUID

    var body: some View {
        if let (trackIndex, transition) = editor.state.transition(id),
           let placed = editor.state.tracks[trackIndex].placedTransitions().first(where: { $0.transition.id == id }) {
            let isCrossfade = editor.state.tracks[trackIndex].kind == .audio
            InspectorSection(title: isCrossfade ? "Crossfade" : "Transition") {
                if isCrossfade {
                    Picker("Curve", selection: Binding(
                        get: { transition.curve },
                        set: { editor.setCrossfadeCurve($0, for: id) }
                    )) {
                        ForEach(FadeCurve.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                } else {
                    Picker("Kind", selection: Binding(
                        get: { transition.kind },
                        set: { editor.setTransitionKind($0, for: id) }
                    )) {
                        ForEach(TransitionKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                }

                InspectorSlider(title: "Length", value: transition.duration.seconds, range: 0.1...3, unit: "s",
                                fractionDigits: 2, unitsPerPoint: 0.01,
                                onBegin: { editor.store.beginLiveEdit() },
                                onChange: { editor.setTransitionDuration(Time(seconds: $0), for: id) },
                                onEnd: { editor.store.commitLiveEdit("Change Transition Length") },
                                onSet: { editor.setTransitionDuration(Time(seconds: $0), for: id) })

                if placed.duration < transition.duration {
                    Text("Shortened to \(String(format: "%.2f", placed.duration.seconds)) s to fit its clips.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                InspectorValueRow(title: placed.isEdge ? "On" : "Between", value: placed.description)

                Button(isCrossfade ? "Delete Crossfade" : "Delete Transition", role: .destructive) { editor.deleteTransition(id) }
                    .controlSize(.small)
            }
            .disabled(editor.state.tracks[trackIndex].isLocked)
        }
    }
}
