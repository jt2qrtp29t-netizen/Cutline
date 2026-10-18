import SwiftUI

/// The project creation window shown at launch.
struct LaunchView: View {
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("launch.lastLocation") private var location = LaunchView.defaultLocation
    @State private var name = "Untitled Project"
    @State private var preset: ResolutionPreset = .hd1080
    @State private var customWidth = 2560
    @State private var customHeight = 1440
    @State private var frameRate = 30
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var recents: [RecentProjects.Entry] = []

    private static var defaultLocation: String {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return movies.appendingPathComponent("Cutline").path
    }

    var body: some View {
        HStack(spacing: 0) {
            createPanel
                .frame(width: 440)
            Rectangle().fill(Theme.border).frame(width: 1)
            recentPanel
                .frame(width: 360)
        }
        .frame(height: 520)
        .background(Theme.background)
        .onAppear { recents = RecentProjects.entries() }
    }

    // MARK: Create

    private var createPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "film.stack")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48)
                    .background(Theme.accentMuted, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cutline")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Create a new project")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 36)
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 16) {
                FieldRow(label: "Name") {
                    TextField("Project name", text: $name)
                        .themedField()
                        .onSubmit(create)
                }
                FieldRow(label: "Location") {
                    HStack(spacing: 8) {
                        Text((location as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Theme.recessed, in: .rect(cornerRadius: Theme.Metrics.controlCornerRadius))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius)
                                    .strokeBorder(Theme.border)
                            }
                            .help(location)
                        Button("Choose…", action: chooseLocation)
                    }
                }
                FieldRow(label: "Resolution") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Resolution", selection: $preset) {
                            ForEach(ResolutionPreset.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)

                        if preset == .custom {
                            HStack(spacing: 6) {
                                TextField("Width", value: $customWidth, format: .number.grouping(.never))
                                    .themedField()
                                    .frame(width: 80)
                                Text("×").foregroundStyle(Theme.textTertiary)
                                TextField("Height", value: $customHeight, format: .number.grouping(.never))
                                    .themedField()
                                    .frame(width: 80)
                                Text("px").foregroundStyle(Theme.textTertiary)
                            }
                            .font(.system(size: 12))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if let size = preset.size {
                            Text("\(size.width) × \(size.height)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .animation(.snappy(duration: 0.2), value: preset)
                }
                FieldRow(label: "Frame rate") {
                    Picker("Frame rate", selection: $frameRate) {
                        ForEach(ProjectSettings.supportedFrameRates, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            Spacer(minLength: 16)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.destructive)
                    .padding(.bottom, 10)
            }

            HStack {
                Spacer()
                Button(action: create) {
                    Text("Create Project")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.textOnAccent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || isCreating)
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
    }

    // MARK: Recents

    private var recentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Recent Projects")
                Spacer()
                if !recents.isEmpty {
                    Button("Clear") {
                        RecentProjects.clear()
                        recents = []
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 10)

            if recents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No recent projects")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(recents) { entry in
                            RecentProjectRow(entry: entry) { open(entry.url) }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.never)
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            HStack {
                Button {
                    NSDocumentController.shared.openDocument(nil)
                } label: {
                    Label("Open Other…", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(16)
        }
        .background(Theme.recessed)
    }

    // MARK: Actions

    private var canCreate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else { return false }
        if preset == .custom {
            return (16...8192).contains(customWidth) && (16...8192).contains(customHeight)
        }
        return true
    }

    private var settings: ProjectSettings {
        let size = preset.size ?? (customWidth, customHeight)
        // Codecs need even dimensions.
        return ProjectSettings(
            name: name.trimmingCharacters(in: .whitespaces),
            width: size.width - size.width % 2,
            height: size.height - size.height % 2,
            frameRate: frameRate
        )
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: location)
        if panel.runModal() == .OK, let url = panel.url {
            location = url.path
        }
    }

    private func create() {
        guard canCreate, !isCreating else { return }
        errorMessage = nil
        let settings = settings
        let folder = URL(fileURLWithPath: location, isDirectory: true)
        let url = folder.appendingPathComponent(settings.name).appendingPathExtension("cutline")

        if FileManager.default.fileExists(atPath: url.path) {
            errorMessage = "A project named “\(settings.name)” already exists here."
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var project = ProjectState(settings: settings)
            project.id = UUID()
            try project.encoded().write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        open(url)
    }

    private func open(_ url: URL) {
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                try await openDocument(at: url)
                RecentProjects.note(url)
                dismissWindow(id: WindowID.launch)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RecentProjectRow: View {
    let entry: RecentProjects.Entry
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.system(size: 14))
                    .foregroundStyle(isHovering ? Theme.accent : Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.raised, in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(entry.folder)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let modified = entry.modified {
                    Text(modified, format: .relative(presentation: .named))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovering ? Theme.raised : Theme.raised.opacity(0), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.url.path)
    }
}
