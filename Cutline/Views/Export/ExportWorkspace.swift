import SwiftUI

/// The Export tab: what to export on the left, the frame being exported in the middle,
/// settings, the estimate and the queue on the right.
struct ExportWorkspace: View {
    let editor: EditorController

    @AppStorage("layout.exportLeftWidth") private var leftWidth = 300.0
    @AppStorage("layout.exportRightWidth") private var rightWidth = 360.0

    var body: some View {
        let source = editor.exportSource
        let sourceEditor = editor.exportEditor(for: source)
        let layout = HStack(spacing: 0) {
            ExportSourcePanel(editor: editor)
                .frame(width: leftWidth)
            PanelDivider(axis: .vertical, size: $leftWidth, range: 260...440)
            center(source: source, sourceEditor: sourceEditor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider(axis: .vertical, size: $rightWidth, range: 300...520, direction: -1)
            ExportSettingsPanel(editor: editor)
                .frame(width: rightWidth)
        }
        // The project window already keeps its own editor in sync; the Playground's
        // needs it here when it's the source.
        if source == .playground {
            layout.editorSync(sourceEditor).id(source)
        } else {
            layout.id(source)
        }
    }
}

extension ExportWorkspace {
    /// The preview, or the frames being exported while an export runs (Parameters can hide them).
    @ViewBuilder
    private func center(source: ExportSource, sourceEditor: EditorController) -> some View {
        let running = ExportQueue.shared.current
        if let running, AppSettings.shared.showFramesWhileExporting {
            let (width, height) = running.snapshot.settings.resolution.size(for: running.snapshot.state.settings)
            ExportLiveView(job: running, aspectRatio: CGFloat(width) / CGFloat(max(height, 1)))
        } else {
            PreviewPanel(editor: sourceEditor)
                .overlay(alignment: .topTrailing) {
                    if source == .playground { SandboxBadge().padding(12) }
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        ExportRangeBadge(editor: editor)
                        if let running { ExportHiddenFramesBadge(job: running) }
                    }
                    .padding(12)
                }
        }
    }
}

/// Which part is being exported, over the preview.
private struct ExportRangeBadge: View {
    let editor: EditorController

    var body: some View {
        let fps = editor.exportEditor(for: editor.exportSource).fps
        Group {
            if let range = editor.exportRange(for: editor.exportSource) {
                Text("Exporting \(Timecode.string(for: range.start, fps: fps)) – \(Timecode.string(for: range.end, fps: fps))")
            } else {
                Text("Nothing to export in this range")
            }
        }
        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.raised.opacity(0.9), in: .capsule)
        .allowsHitTesting(false)
    }
}

/// Left panel: source, range, variants and presets.
struct ExportSourcePanel: View {
    let editor: EditorController

    @AppStorage("export.variants") private var variantChoice = VariantExport.asShown.rawValue

    var body: some View {
        let source = editor.exportSource
        let settings = editor.exportSettings(for: source)
        let sourceEditor = editor.exportEditor(for: source)
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Export")
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    InspectorSection(title: "Source") {
                        Picker("Source", selection: Binding(get: { editor.exportSource }, set: { editor.exportSource = $0 })) {
                            ForEach(ExportSource.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if source == .playground {
                            Label("Exports the sandbox timeline. Your project isn’t changed.", systemImage: "flask")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.sandbox)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    InspectorSection(title: "Range") {
                        Picker("Range", selection: Binding(get: { settings.range },
                                                           set: { kind in editor.updateExportSettings(for: source) { $0.range = kind } })) {
                            ForEach(ExportRangeKind.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        switch settings.range {
                        case .all:
                            EmptyView()
                        case .inOut:
                            inOutControls(settings: settings, sourceEditor: sourceEditor)
                        case .selection:
                            let clips = sourceEditor.selectedClips
                            Text(clips.isEmpty ? "Select clips on the timeline below."
                                 : "\(clips.count) clip\(clips.count == 1 ? "" : "s") selected.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    if source == .playground, editor.selectedPlaygroundVariantGroup != nil {
                        InspectorSection(title: "Variants") {
                            Picker("Variants", selection: $variantChoice) {
                                ForEach(VariantExport.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            Text("The selected clip has variants. Export it as shown, only the selected variant, or each variant as its own file (-A, -B…).")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    InspectorSection(title: "Presets") {
                        ForEach(ExportPreset.all) { preset in
                            PresetRow(preset: preset, isSelected: settings.presetID == preset.id) {
                                editor.updateExportSettings(for: source) { $0 = preset.applied(to: $0) }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func inOutControls(settings: ExportSettings, sourceEditor: EditorController) -> some View {
        let fps = sourceEditor.fps
        let source = editor.exportSource
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("In").frame(width: 28, alignment: .leading)
                Text(Timecode.string(for: settings.inPoint ?? .zero, fps: fps))
                    .monospacedDigit()
                Spacer()
                Button("Set at Playhead") {
                    let t = sourceEditor.playback.currentTime.snappedToFrame(fps: fps)
                    editor.updateExportSettings(for: source) { $0.inPoint = t }
                }
                .controlSize(.small)
            }
            HStack {
                Text("Out").frame(width: 28, alignment: .leading)
                Text(Timecode.string(for: settings.outPoint ?? sourceEditor.state.duration, fps: fps))
                    .monospacedDigit()
                Spacer()
                Button("Set at Playhead") {
                    let t = sourceEditor.playback.currentTime.snappedToFrame(fps: fps)
                    editor.updateExportSettings(for: source) { $0.outPoint = t }
                }
                .controlSize(.small)
            }
            if settings.inPoint != nil || settings.outPoint != nil {
                Button("Clear In and Out") {
                    editor.updateExportSettings(for: source) {
                        $0.inPoint = nil
                        $0.outPoint = nil
                    }
                }
                .controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
    }
}

private struct PresetRow: View {
    let preset: ExportPreset
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(preset.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accentMuted : (isHovering ? Theme.raisedHover : Theme.raised.opacity(0.4)),
                        in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
