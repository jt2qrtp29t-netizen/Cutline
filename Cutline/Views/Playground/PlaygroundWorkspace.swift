import SwiftUI

/// The Playground tab: adjustments on the left, the sandbox preview in the middle,
/// Labs, variants and snapshots on the right, and the scratch timeline below (placed
/// by the window). Everything here works on the Playground's own editor.
struct PlaygroundWorkspace: View {
    let main: EditorController
    let session: PlaygroundSession

    @AppStorage("layout.playgroundLeftWidth") private var leftWidth = 340.0
    @AppStorage("layout.playgroundRightWidth") private var rightWidth = 330.0

    private var sandbox: EditorController { session.editor }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("Panel", selection: Binding(get: { sandbox.sandboxPanel }, set: { sandbox.sandboxPanel = $0 })) {
                    ForEach(SandboxPanel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                Rectangle().fill(Theme.border).frame(height: 1)
                switch sandbox.sandboxPanel {
                case .adjust: InspectorPanel(editor: sandbox)
                case .effects: EffectsPanel(editor: sandbox)
                case .color: ColorPanel(editor: sandbox)
                }
            }
            .frame(width: leftWidth)
            .background(Theme.background)
            PanelDivider(axis: .vertical, size: $leftWidth, range: 280...560)

            PreviewPanel(editor: sandbox)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) { SandboxBadge().padding(12) }

            PanelDivider(axis: .vertical, size: $rightWidth, range: 260...520, direction: -1)
            PlaygroundSidePanel(main: main, session: session)
                .frame(width: rightWidth)
        }
        .editorSync(sandbox)
        .onChange(of: sandbox.store.state) { session.scheduleSave() }
        .onChange(of: session.variants) { session.scheduleSave() }
        .onChange(of: session.snapshots) { session.scheduleSave() }
        .onChange(of: session.disabledExperiments) { session.scheduleSave() }
    }
}

/// "Sandbox" label so the Playground is never mistaken for the real timeline.
struct SandboxBadge: View {
    var body: some View {
        Label("Sandbox", systemImage: "flask")
            .font(.system(size: 10, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.sandbox)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.sandboxMuted, in: .capsule)
            .overlay { Capsule().strokeBorder(Theme.sandbox.opacity(0.6)) }
            .allowsHitTesting(false)
            .help("This is the Playground: nothing here changes your project.")
    }
}

/// Right panel: Labs, variants and snapshots, plus resetting the Playground.
struct PlaygroundSidePanel: View {
    let main: EditorController
    let session: PlaygroundSession

    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Playground")
                Spacer()
                Button("Reset…") { confirmReset = true }
                    .controlSize(.small)
                    .help("Clear the Playground")
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let problem = session.loadProblem ?? session.saveProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.offlineBadge)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    InspectorSection(title: "About") {
                        Text("Experiment freely here: this timeline, its undo history and everything on it are separate from your project. Right-click clips in Edit and choose Send to Playground to bring copies in.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.background)
        .confirmationDialog("Reset the Playground?", isPresented: $confirmReset) {
            Button("Reset Playground", role: .destructive) { session.reset() }
        } message: {
            Text("This clears the scratch timeline, its variants, snapshots and Labs settings. Your project isn’t affected. This can’t be undone.")
        }
    }
}
