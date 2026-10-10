import SwiftUI

/// A transition drawn over its cut: a band covering the frames it plays across.
/// Click to select it (its settings appear in the Effects tab); right-click to
/// change or remove it.
struct TransitionMarker: View {
    let editor: EditorController
    let placed: PlacedTransition
    let isLocked: Bool

    private var isSelected: Bool { editor.selectedTransition == placed.transition.id }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        ZStack {
            shape.fill(Theme.transitionFill)
            Image(systemName: placed.transition.kind.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.transitionBorderSelected : Theme.transitionBorder)
        }
        .overlay {
            shape.strokeBorder(isSelected ? Theme.transitionBorderSelected : Theme.transitionBorder,
                               lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(shape)
        .help("\(placed.transition.kind.title) · \(String(format: "%.2f", placed.duration.seconds)) s")
        .onTapGesture {
            editor.selectTransition(placed.transition.id)
        }
        .contextMenu {
            Picker("Transition", selection: Binding(
                get: { placed.transition.kind },
                set: { editor.setTransitionKind($0, for: placed.transition.id) }
            )) {
                ForEach(TransitionKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbolName).tag(kind)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Delete Transition", role: .destructive) {
                editor.deleteTransition(placed.transition.id)
            }
        }
        .disabled(isLocked)
    }
}
