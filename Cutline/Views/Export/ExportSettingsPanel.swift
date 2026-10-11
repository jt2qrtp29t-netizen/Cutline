import SwiftUI

/// Right panel: settings, the estimate, where to save, and the queue.
struct ExportSettingsPanel: View {
    let editor: EditorController

    @AppStorage("export.variants") private var variantChoice = VariantExport.asShown.rawValue
    @State private var fileName = ""
    @State private var pending: PendingExport?

    private struct PendingExport: Identifiable {
        let id = UUID()
        let jobs: [ExportJob]
        let warnings: [String]
        let overwriting: [String]
    }

    private var source: ExportSource { editor.exportSource }

    var body: some View {
        let settings = editor.exportSettings(for: source)
        let project = editor.exportEditor(for: source).state.settings
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Settings")
                Spacer()
                Text(ExportPreset.preset(settings.presetID)?.name ?? "Custom")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    videoSection(settings, project: project)
                    audioSection(settings)
                    estimateSection(settings, project: project)
                    outputSection(settings)
                    ExportQueueSection()
                }
                .padding(12)
            }
        }
        .background(Theme.background)
        .onAppear { fileName = settings.fileName ?? editor.defaultExportName(for: source) }
        .onChange(of: source) { fileName = editor.exportSettings(for: source).fileName ?? editor.defaultExportName(for: source) }
        .sheet(item: $pending) { pending in
            ExportConfirmation(warnings: pending.warnings, overwriting: pending.overwriting) {
                pending.jobs.forEach(ExportQueue.shared.enqueue)
                self.pending = nil
            } cancel: {
                self.pending = nil
            }
        }
    }

    /// A settings change made by hand: the preset becomes Custom.
    private func change(_ body: @escaping (inout ExportSettings) -> Void) {
        editor.updateExportSettings(for: source) { settings in
            body(&settings)
            settings.presetID = ExportPreset.custom.id
        }
    }

    // MARK: Sections

    private func videoSection(_ settings: ExportSettings, project: ProjectSettings) -> some View {
        let size = settings.resolution.size(for: project)
        let customSize: (Int, Int)? = if case let .custom(w, h) = settings.resolution { (w, h) } else { nil }
        let differentShape = abs(Double(size.width) / Double(size.height) - Double(project.width) / Double(max(project.height, 1))) > 0.01
        return InspectorSection(title: "Video") {
            LabeledPicker("Size", selection: Binding(get: { customSize == nil ? settings.resolution.title : "Custom" },
                                                     set: { title in
                                                         if title == "Custom" {
                                                             change { $0.resolution = .custom(width: size.width, height: size.height) }
                                                         } else if let choice = ExportResolution.choices.first(where: { $0.title == title }) {
                                                             change { $0.resolution = choice }
                                                         }
                                                     }),
                          options: ExportResolution.choices.map(\.title) + ["Custom"])
            if let customSize {
                HStack(spacing: 6) {
                    Text("").frame(width: 82)
                    NumberField(value: Double(customSize.0), range: 16...8192, displayScale: 1, unit: "", fractionDigits: 0, step: 2) { w in
                        change { $0.resolution = .custom(width: Int(w), height: customSize.1) }
                    }
                    Text("×").foregroundStyle(Theme.textTertiary)
                    NumberField(value: Double(customSize.1), range: 16...8192, displayScale: 1, unit: "", fractionDigits: 0, step: 2) { h in
                        change { $0.resolution = .custom(width: customSize.0, height: Int(h)) }
                    }
                }
            }
            Text("\(size.width) × \(size.height)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 88)
            if differentShape {
                LabeledPicker("Shape", selection: Binding(get: { settings.fit.title },
                                                          set: { t in change { $0.fit = t == ExportFit.fit.title ? .fit : .fill } }),
                              options: ExportFit.allCases.map(\.title))
            }
            LabeledPicker("Frame Rate", selection: Binding(
                get: { settings.frameRate.map { "\($0) fps" } ?? "Project (\(project.frameRate) fps)" },
                set: { t in change { $0.frameRate = t.hasPrefix("Project") ? nil : Int(t.prefix(while: \.isNumber)) } }),
                          options: ["Project (\(project.frameRate) fps)"] + [24, 25, 30, 50, 60].map { "\($0) fps" })
            LabeledPicker("Codec", selection: Binding(get: { settings.codec.title },
                                                      set: { t in change { s in s.codec = ExportCodec.allCases.first { $0.title == t } ?? .h264 } }),
                          options: ExportCodec.allCases.map(\.title))
            LabeledPicker("Container", selection: Binding(get: { settings.effectiveContainer.title },
                                                          set: { t in change { s in s.container = ExportContainer.allCases.first { $0.title == t } ?? .mp4 } }),
                          options: ExportContainer.allCases.map(\.title))
                .disabled(settings.codec == .proRes422)
            if settings.codec.usesBitrate {
                InspectorSlider(title: "Quality", value: settings.quality, range: 0...1, displayScale: 100, unit: "%",
                                onBegin: {}, onChange: { q in change { $0.quality = q } }, onEnd: {},
                                onSet: { q in change { $0.quality = q } })
                Text(String(format: "About %.0f Mbit/s", settings.videoBitrate(for: project) / 1_000_000))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 88)
            }
            Toggle("Hardware encoding", isOn: Binding(get: { settings.hardwareEncoding },
                                                       set: { on in change { $0.hardwareEncoding = on } }))
                .font(.system(size: 11))
            if settings.codec.usesBitrate {
                Toggle("Faster encoding", isOn: Binding(get: { settings.fastEncoding },
                                                         set: { on in change { $0.fastEncoding = on } }))
                    .font(.system(size: 11))
                    .disabled(!settings.hardwareEncoding)
                    .help("Lets the hardware encoder favor speed, about 1.7× faster in 4K at the same bitrate. Turn off for the very best quality.")
            }
        }
    }

    private func audioSection(_ settings: ExportSettings) -> some View {
        InspectorSection(title: "Audio (AAC)") {
            LabeledPicker("Bitrate", selection: Binding(get: { "\(settings.audioBitrate) kbit/s" },
                                                        set: { t in change { $0.audioBitrate = Int(t.prefix(while: \.isNumber)) ?? 192 } }),
                          options: ExportSettings.audioBitrates.map { "\($0) kbit/s" })
            LabeledPicker("Sample Rate", selection: Binding(get: { "\(settings.audioSampleRate) Hz" },
                                                            set: { t in change { $0.audioSampleRate = Int(t.prefix(while: \.isNumber)) ?? 48_000 } }),
                          options: ExportSettings.audioSampleRates.map { "\($0) Hz" })
            LabeledPicker("Channels", selection: Binding(get: { settings.audioChannels == 1 ? "Mono" : "Stereo" },
                                                         set: { t in change { $0.audioChannels = t == "Mono" ? 1 : 2 } }),
                          options: ["Stereo", "Mono"])
        }
    }

    private func estimateSection(_ settings: ExportSettings, project: ProjectSettings) -> some View {
        let range = editor.exportRange(for: source)
        let seconds = range?.duration.seconds ?? 0
        let fps = settings.frameRate(for: project)
        let frames = ExportSnapshot.frameCount(range?.duration ?? .zero, fps: fps)
        let size = settings.resolution.size(for: project)
        return InspectorSection(title: "Estimate") {
            if range == nil {
                Label("Nothing to export in this range.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.offlineBadge)
            } else {
                InspectorValueRow(title: "Length", value: "\(Timecode.string(for: range!.duration, fps: fps)) · \(frames) frames")
                InspectorValueRow(title: "File size", value: "about " + ByteCountFormatter.string(
                    fromByteCount: Int64(settings.estimatedBytes(seconds: seconds, project: project)), countStyle: .file))
                InspectorValueRow(title: "Export time", value: Self.duration(ExportTimeEstimate.seconds(
                    frames: frames, width: size.width, height: size.height, codec: settings.codec)))
            }
        }
    }

    private func outputSection(_ settings: ExportSettings) -> some View {
        let folder = editor.exportFolder(for: source)
        let ext = settings.effectiveContainer.fileExtension
        return InspectorSection(title: "Save As") {
            HStack(spacing: 4) {
                TextField("File name", text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.updateExportSettings(for: source) { $0.fileName = fileName } }
                Text(".\(ext)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.textTertiary)
                Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder() }
                    .controlSize(.small)
            }
            Button {
                startExport()
            } label: {
                Label(source == .playground ? "Export Playground" : "Export", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(source == .playground ? Theme.sandbox : Theme.accent)
            .disabled(editor.exportRange(for: source) == nil || fileName.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Exports run in the background, so you can keep editing. Later edits don’t change an export that has started.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = editor.exportFolder(for: source)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.updateExportSettings(for: source) { $0.folderPath = url.path }
    }

    private func startExport() {
        let name = fileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        editor.updateExportSettings(for: source) { $0.fileName = name == editor.defaultExportName(for: source) ? nil : name }
        let variants = VariantExport(rawValue: variantChoice) ?? .asShown
        do {
            let jobs = try editor.makeExportJobs(source: source, fileName: name, folder: editor.exportFolder(for: source),
                                                 variants: editor.selectedPlaygroundVariantGroup == nil ? .asShown : variants)
            let busy = Set(ExportQueue.shared.jobs.filter { !$0.status.isFinished }.map(\.destination.path))
            let overwriting = jobs.map(\.destination).filter { FileManager.default.fileExists(atPath: $0.path) || busy.contains($0.path) }
                .map(\.lastPathComponent)
            let warnings = editor.exportPreflightWarnings(for: source)
            if warnings.isEmpty && overwriting.isEmpty {
                jobs.forEach(ExportQueue.shared.enqueue)
            } else {
                pending = PendingExport(jobs: jobs, warnings: warnings, overwriting: overwriting)
            }
        } catch {
            editor.alert = EditorAlert(title: "Nothing to export", message: error.localizedDescription)
        }
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "under a second" }
        if seconds < 60 { return "about \(Int(seconds.rounded())) s" }
        let minutes = Int((seconds / 60).rounded())
        return "about \(minutes) min"
    }
}

/// A rough guess at how long an export takes, refined by the last export's measured speed.
enum ExportTimeEstimate {
    /// Frames per second at 1080p, from the last export (or a typical Apple silicon speed).
    nonisolated(unsafe) static var measured1080pFramesPerSecond = 90.0

    static func seconds(frames: Int, width: Int, height: Int, codec: ExportCodec) -> Double {
        let pixels = Double(width * height) / (1920 * 1080)
        let codecCost = codec == .hevc ? 1.3 : 1
        return Double(frames) / measured1080pFramesPerSecond * pixels * codecCost
    }
}

/// A label and a pop-up menu, aligned like the other settings.
private struct LabeledPicker: View {
    let title: String
    let selection: Binding<String>
    let options: [String]

    init(_ title: String, selection: Binding<String>, options: [String]) {
        self.title = title
        self.selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 82, alignment: .leading)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

/// Asks before exporting with missing files or over an existing file.
private struct ExportConfirmation: View {
    let warnings: [String]
    let overwriting: [String]
    let proceed: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Before you export", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if !overwriting.isEmpty {
                Text("These files already exist (or are being exported) and will be replaced:")
                    .font(.system(size: 12))
                ForEach(overwriting, id: \.self) { Text("• \($0)").font(.system(size: 12, weight: .medium)) }
            }
            if !warnings.isEmpty {
                Text("Some things are missing. You can export without them or cancel and fix them first:")
                    .font(.system(size: 12))
                ForEach(warnings, id: \.self) {
                    Text("• \($0)")
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(overwriting.isEmpty ? "Export Anyway" : "Replace and Export", action: proceed)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .foregroundStyle(Theme.textSecondary)
    }
}
