import SwiftUI

/// The main editor window: inspector | preview | media bin above the timeline.
struct EditorView: View {
    let document: CutlineDocument

    @State private var editor: EditorController
    @Environment(\.undoManager) private var undoManager
    @Environment(\.documentConfiguration) private var documentConfiguration

    @AppStorage("layout.inspectorWidth") private var inspectorWidth = Double(Theme.Metrics.inspectorWidth)
    @AppStorage("layout.binWidth") private var binWidth = Double(Theme.Metrics.mediaBinWidth)
    @AppStorage("layout.timelineHeight") private var timelineHeight = 300.0
    @AppStorage("layout.curveWidth") private var curveWidth = 360.0
    @AppStorage("layout.colorPanelWidth") private var colorPanelWidth = 480.0
    @AppStorage("layout.scopesWidth") private var scopesWidth = 340.0

    init(document: CutlineDocument) {
        self.document = document
        _editor = State(initialValue: EditorController(store: document.store))
    }

    /// The file name without extension, falling back to the project name.
    private var title: String {
        documentConfiguration?.fileURL?.deletingPathExtension().lastPathComponent ?? editor.settings.name
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorTitleBar(editor: editor, title: title)
            WorkspaceTabBar(editor: editor)
            workspaceContent
                .frame(maxHeight: .infinity)
                // Files dropped anywhere above the timeline go into the media bin.
                .dropDestination(for: URL.self) { urls, _ in
                    editor.activeEditor.importMedia(urls)
                    return true
                }
            PanelDivider(axis: .horizontal, size: $timelineHeight, range: 180...640, direction: -1)
            // The Playground has its own scratch timeline.
            if editor.showsPlaygroundTimeline, let playground = editor.playground {
                TimelinePanel(editor: playground.editor)
                    .id(ObjectIdentifier(playground.editor))
                    .frame(height: timelineHeight)
                    .overlay(alignment: .topTrailing) { SandboxBadge().padding(.top, 7).padding(.trailing, 200) }
            } else {
                TimelinePanel(editor: editor)
                    .frame(height: timelineHeight)
            }
        }
        // The system title bar is hidden; our own bar sits under the window buttons.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1080, minHeight: 680)
        .background {
            // ⌘= is what most keyboards send for "⌘+"; the menu item shows ⌘+.
            Button("Zoom In") { editor.activeEditor.zoomIn() }
                .keyboardShortcut("=")
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(Theme.background)
        .containerBackground(Theme.background, for: .window)
        .navigationTitle(title)
        .focusedSceneValue(\.editor, editor)
        .editorSync(editor)
        .background(ScrollTabSwitcher(editor: editor))
        .background(BeforeKeyMonitor(editor: editor))
        .onAppear {
            editor.store.undoManager = undoManager
            editor.projectFileURL = documentConfiguration?.fileURL
            if let url = documentConfiguration?.fileURL { RecentProjects.note(url) }
        }
        .onDisappear {
            editor.playback.pause()
            editor.playground?.deactivate()
        }
        .onChange(of: undoManager) { _, newValue in
            editor.store.undoManager = newValue
        }
    }

    /// The area above the timeline for the current workspace tab.
    @ViewBuilder
    private var workspaceContent: some View {
        switch editor.workspace {
        case .edit:
            HStack(spacing: 0) {
                InspectorPanel(editor: editor)
                    .frame(width: inspectorWidth)
                PanelDivider(axis: .vertical, size: $inspectorWidth, range: 260...460)
                PreviewPanel(editor: editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PanelDivider(axis: .vertical, size: $binWidth, range: 200...460, direction: -1)
                MediaBinPanel(editor: editor)
                    .frame(width: binWidth)
            }
        case .effects:
            HStack(spacing: 0) {
                EffectsPanel(editor: editor)
                    .frame(width: inspectorWidth)
                PanelDivider(axis: .vertical, size: $inspectorWidth, range: 260...460)
                PreviewPanel(editor: editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PanelDivider(axis: .vertical, size: $curveWidth, range: 260...620, direction: -1)
                CurveEditorPanel(editor: editor)
                    .frame(width: curveWidth)
            }
        case .color:
            HStack(spacing: 0) {
                ColorPanel(editor: editor)
                    .frame(width: colorPanelWidth)
                PanelDivider(axis: .vertical, size: $colorPanelWidth, range: 400...720)
                PreviewPanel(editor: editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PanelDivider(axis: .vertical, size: $scopesWidth, range: 260...560, direction: -1)
                ScopesPanel(editor: editor)
                    .frame(width: scopesWidth)
            }
        case .playground:
            if let playground = editor.playground {
                PlaygroundWorkspace(main: editor, session: playground)
            }
        case .export:
            ExportWorkspace(editor: editor)
        }
    }
}
