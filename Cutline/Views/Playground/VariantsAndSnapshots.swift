import SwiftUI

/// Variants of the selected clip: make them, switch between them or view them side by
/// side, and keep the best.
struct VariantsSection: View {
    let session: PlaygroundSession
    private var sandbox: EditorController { session.editor }

    var body: some View {
        InspectorSection(title: "Variants") {
            if let clip = sandbox.selectedClips.first, sandbox.selectedClips.count == 1,
               sandbox.state.track(ofClip: clip.id)?.kind.isVisual == true {
                if let group = session.variantGroup(containing: clip.id) {
                    HStack(spacing: 4) {
                        ForEach(Array(group.clipIDs.enumerated()), id: \.element) { index, id in
                            Button(VariantGroup.letter(index)) { session.showVariant(index, in: group.id) }
                                .buttonStyle(VariantButtonStyle(isActive: group.compare == .toggle && index == group.active,
                                                                isSelected: id == clip.id))
                                .help(sandbox.state.clip(id)?.name ?? "")
                        }
                        Button {
                            session.makeVariant(of: clip.id)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(VariantButtonStyle(isActive: false, isSelected: false))
                        .help("Add another variant")
                    }
                    Picker("Compare", selection: Binding(get: { group.compare }, set: { session.setCompare($0, for: group.id) })) {
                        Text("One at a Time").tag(VariantGroup.Compare.toggle)
                        Text("Side by Side").tag(VariantGroup.Compare.split)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    HStack {
                        Button("Keep \(VariantGroup.letter(group.clipIDs.firstIndex(of: clip.id) ?? 0)) Only") {
                            session.keepOnly(clip.id, in: group.id)
                        }
                        .controlSize(.small)
                        .help("Delete the other variants")
                        Button("Stop Comparing") { session.ungroup(group.id) }
                            .controlSize(.small)
                            .help("Keep all variants as ordinary clips")
                    }
                    Text("Each variant is its own clip: select one and change its grade, effects or animation. Click a letter to see that variant.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Make Variants of “\(clip.name)”") { session.makeVariant(of: clip.id) }
                        .controlSize(.small)
                    Text("Duplicates the clip so you can try different grades, effects or animations on the same footage, then compare them.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Select one video or text clip to make variants of it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct VariantButtonStyle: ButtonStyle {
    let isActive: Bool
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isActive ? Theme.background : Theme.textPrimary)
            .frame(width: 30, height: 24)
            .background(isActive ? Theme.sandbox : Theme.raised, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Theme.sandbox : Theme.border, lineWidth: isSelected ? 1.5 : 1)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Named checkpoints of the whole Playground.
struct SnapshotsSection: View {
    let session: PlaygroundSession
    @State private var name = ""
    @State private var renaming: UUID?
    @State private var newName = ""

    var body: some View {
        InspectorSection(title: "Snapshots") {
            HStack(spacing: 6) {
                TextField("Snapshot name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(save)
                Button("Save", action: save)
                    .controlSize(.small)
            }
            if session.snapshots.isEmpty {
                Text("Save a snapshot to come back to this exact Playground later.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(session.snapshots) { snapshot in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        if renaming == snapshot.id {
                            TextField("Name", text: $newName)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .onSubmit {
                                    session.renameSnapshot(snapshot.id, to: newName)
                                    renaming = nil
                                }
                        } else {
                            Text(snapshot.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        }
                        Text("\(snapshot.date.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.project.allClips.count) clips")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Button("Restore") { session.restore(snapshot) }
                        .controlSize(.small)
                        .help("Put the Playground back to this snapshot (undoable)")
                    Menu {
                        Button("Rename…") {
                            newName = snapshot.name
                            renaming = snapshot.id
                        }
                        Button("Delete", role: .destructive) { session.deleteSnapshot(snapshot.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func save() {
        session.saveSnapshot(named: name)
        name = ""
    }
}

/// Labels over the Playground preview: which variant is showing, or A | B | C slices.
struct VariantPreviewLabels: View {
    let session: PlaygroundSession

    var body: some View {
        let sandbox = session.editor
        let time = sandbox.playback.currentTime
        // The group of the selected clip, or one that's on screen now.
        let group = sandbox.selectedClips.first.flatMap { session.variantGroup(containing: $0.id) }
            ?? session.liveVariants.first { group in
                group.clipIDs.contains { sandbox.state.clip($0)?.range.contains(time) == true }
            }
        if let group {
            switch group.compare {
            case .toggle:
                VStack {
                    Text("VARIANT \(VariantGroup.letter(group.active))")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.sandbox, in: .capsule)
                    Spacer()
                }
                .padding(.top, 34)
            case .split:
                HStack(spacing: 0) {
                    ForEach(group.clipIDs.indices, id: \.self) { index in
                        Text(VariantGroup.letter(index))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 22, height: 22)
                            .background(Theme.sandbox, in: .circle)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 34)
                            .overlay(alignment: .trailing) {
                                if index < group.clipIDs.count - 1 {
                                    Rectangle().fill(Theme.sandbox.opacity(0.7)).frame(width: 1)
                                }
                            }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 64)
            }
        }
    }
}
