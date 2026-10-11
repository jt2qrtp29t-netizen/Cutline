import SwiftUI
import UniformTypeIdentifiers

/// The Captions tab: the transcript (left), the preview, and the caption track's
/// settings and style (right). The timeline underneath shows the caption track.
struct CaptionsWorkspace: View {
    let editor: EditorController
    @AppStorage("layout.transcriptWidth") private var transcriptWidth = 400.0
    @AppStorage("layout.captionSettingsWidth") private var settingsWidth = 320.0

    var body: some View {
        HStack(spacing: 0) {
            TranscriptPanel(editor: editor)
                .frame(width: transcriptWidth)
            PanelDivider(axis: .vertical, size: $transcriptWidth, range: 300...640)
            PreviewPanel(editor: editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider(axis: .vertical, size: $settingsWidth, range: 260...460, direction: -1)
            CaptionSettingsPanel(editor: editor)
                .frame(width: settingsWidth)
        }
    }
}

// MARK: - Transcript

/// What was said, caption by caption: click a word to go there, double-click a caption
/// to retype it, right-click to split, merge or hide. The caption being spoken is
/// highlighted (and followed during playback).
struct TranscriptPanel: View {
    let editor: EditorController
    @State private var editingCaptionID: UUID?
    @State private var draft = ""
    @State private var showsHidden = false

    var body: some View {
        let captions = editor.currentCaptions
        let position = editor.captionPosition(in: captions, at: editor.playback.currentTime)
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            if editor.isTranscribing { progress }
            if let message = editor.transcriptionMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sandbox)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            if captions.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(captions.enumerated()), id: \.element.id) { index, caption in
                                CaptionRow(
                                    caption: caption,
                                    fps: editor.fps,
                                    activeWordID: position?.caption.id == caption.id ? position?.word?.wordID : nil,
                                    isActive: position?.caption.id == caption.id,
                                    isEditing: editingCaptionID == caption.id,
                                    canMerge: index > 0,
                                    draft: $draft,
                                    actions: actions(for: caption)
                                )
                                .equatable()
                                .id(caption.id)
                            }
                            hiddenWords
                        }
                        .padding(8)
                    }
                    .onChange(of: position?.caption.id) { _, id in
                        // Follow playback (not while editing).
                        guard let id, editor.playback.isPlaying, editingCaptionID == nil else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            SectionLabel("Transcript")
            Spacer()
            if editor.isTranscribing {
                Button("Cancel") { editor.cancelTranscription() }
                    .controlSize(.small)
            } else {
                Button {
                    editor.transcribeForCaptions()
                } label: {
                    Label(editor.state.transcripts.isEmpty ? "Transcribe" : "Transcribe Again", systemImage: "waveform.badge.mic")
                }
                .controlSize(.small)
                .disabled(editor.state.transcribableMedia.isEmpty)
                .help("Recognizes the speech on the audio tracks, on this Mac. Nothing is uploaded.")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(editor.state.media.filter { editor.transcriptionProgress[$0.id] != nil }) { media in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transcribing \(media.name)…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    ProgressView(value: editor.transcriptionProgress[media.id] ?? 0)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary)
            Text(editor.state.transcribableMedia.isEmpty
                 ? "Add clips with sound to the audio tracks, then transcribe them here."
                 : editor.state.transcripts.isEmpty
                 ? "Transcribe the audio tracks to make captions. Recognition runs on this Mac."
                 : "No captions here: the caption track's audio has no words yet.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Words hidden from the captions, to bring back.
    @ViewBuilder
    private var hiddenWords: some View {
        let hidden = editor.state.transcripts.values.flatMap { t in t.words.filter(\.isHidden).map { (t.mediaID, $0) } }
        if !hidden.isEmpty {
            DisclosureGroup(isExpanded: $showsHidden) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(hidden, id: \.1.id) { mediaID, word in
                        HStack {
                            Text(word.text)
                                .strikethrough()
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Button("Show") { editor.setWordHidden(mediaID: mediaID, wordID: word.id, false) }
                                .controlSize(.mini)
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Hidden words (\(hidden.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)
        }
    }

    private func actions(for caption: Caption) -> CaptionRow.Actions {
        CaptionRow.Actions(
            jump: { time in
                editor.playback.pause()
                editor.playback.seek(to: time)
            },
            beginEditing: {
                draft = caption.text
                editingCaptionID = caption.id
            },
            commit: { text in
                editingCaptionID = nil
                editor.editCaption(caption, to: text)
            },
            cancel: { editingCaptionID = nil },
            split: { editor.splitCaption(at: $0) },
            merge: { editor.mergeWithPrevious(caption) },
            hide: { editor.setWordHidden($0, true) }
        )
    }
}

/// One caption in the transcript: its time and its words.
struct CaptionRow: View, Equatable {
    struct Actions {
        let jump: (Time) -> Void
        let beginEditing: () -> Void
        let commit: (String) -> Void
        let cancel: () -> Void
        let split: (CaptionWord) -> Void
        let merge: () -> Void
        let hide: (CaptionWord) -> Void
    }

    let caption: Caption
    let fps: Int
    let activeWordID: UUID?
    let isActive: Bool
    let isEditing: Bool
    let canMerge: Bool
    @Binding var draft: String
    let actions: Actions

    @FocusState private var focused: Bool

    static func == (a: CaptionRow, b: CaptionRow) -> Bool {
        a.caption == b.caption && a.activeWordID == b.activeWordID && a.isActive == b.isActive
            && a.isEditing == b.isEditing && a.canMerge == b.canMerge && a.fps == b.fps
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Timecode.string(for: caption.start, fps: fps, alwaysShowHours: false))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
                .frame(width: 58, alignment: .leading)
                .onTapGesture { actions.jump(caption.start) }
            if isEditing {
                TextField("Caption", text: $draft, axis: .vertical)
                    .font(.system(size: 12.5))
                    .themedField()
                    .focused($focused)
                    .onSubmit { actions.commit(draft) }
                    .onExitCommand { actions.cancel() }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, isFocused in if !isFocused { actions.commit(draft) } }
            } else {
                WordFlow(spacing: 1, lineSpacing: 3) {
                    ForEach(caption.words, id: \.wordID) { word in
                        Text(word.text)
                            .font(.system(size: 12.5, weight: word.wordID == activeWordID ? .semibold : .regular))
                            .foregroundStyle(word.wordID == activeWordID ? Theme.background : Theme.textPrimary)
                            .padding(.horizontal, 2)
                            .background(word.wordID == activeWordID ? Theme.accent : .clear, in: .rect(cornerRadius: 3))
                            .contentShape(.rect)
                            .onTapGesture(count: 2) { actions.beginEditing() }
                            .onTapGesture { actions.jump(word.start) }
                            .contextMenu {
                                Button("Edit Caption…") { actions.beginEditing() }
                                Button("Start New Caption Here") { actions.split(word) }
                                    .disabled(word.wordID == caption.words.first?.wordID)
                                Button("Merge with Previous Caption") { actions.merge() }
                                    .disabled(!canMerge)
                                Divider()
                                Button("Hide “\(word.text)” from Captions") { actions.hide(word) }
                            }
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Theme.accentMuted : .clear, in: .rect(cornerRadius: 6))
    }
}

/// Lays words out left to right, wrapping like text.
struct WordFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Settings

/// The caption track's settings: what it captions, how words group, and its look.
struct CaptionSettingsPanel: View {
    let editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Captions")
                Spacer()
                Button {
                    editor.selectedCaptionTrackID = editor.addCaptionTrack()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Add a caption track")
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)
            if let index = editor.captionTrackIndex, let settings = editor.state.tracks[index].captions {
                ScrollView {
                    CaptionSettingsForm(editor: editor, track: editor.state.tracks[index], settings: settings)
                        .padding(12)
                }
            } else {
                VStack(spacing: 10) {
                    Text("No caption track yet.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                    Button("Add Caption Track") { editor.selectedCaptionTrackID = editor.addCaptionTrack() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
    }
}

struct CaptionSettingsForm: View {
    let editor: EditorController
    let track: Track
    let settings: CaptionSettings

    private func exportSubtitles() {
        guard let index = editor.state.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = "\(editor.state.settings.name).srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = SubtitleFile.srt(editor.state.captions(onTrack: index), uppercase: settings.style.isUppercase)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            editor.transcriptionMessage = "Couldn't save the captions: \(error.localizedDescription)"
        }
    }

    private func adjust(_ name: String, _ body: @escaping (inout CaptionSettings) -> Void) {
        editor.adjustCaptions(track.id, actionName: name, body)
    }

    private func slider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, unit: String = " s", digits: Int = 1,
                        action: String, _ set: @escaping (inout CaptionSettings, Double) -> Void) -> some View {
        InspectorSlider(title: title, value: value, range: range, unit: unit, fractionDigits: digits,
                        onBegin: editor.beginAdjustment,
                        onChange: { v in adjust(action) { set(&$0, v) } },
                        onEnd: { editor.endAdjustment(action) },
                        onSet: { v in adjust(action) { set(&$0, v) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.captionTrackIndices.count > 1 {
                Picker("Track", selection: Binding(get: { track.id }, set: { editor.selectedCaptionTrackID = $0 })) {
                    ForEach(editor.captionTrackIndices, id: \.self) { i in
                        Text(editor.state.tracks[i].name).tag(editor.state.tracks[i].id)
                    }
                }
                .controlSize(.small)
            }

            InspectorSection(title: "Captions From") {
                let audio = editor.state.trackIndices(of: .audio).map { editor.state.tracks[$0] }
                ForEach(audio) { source in
                    Toggle(source.name, isOn: Binding(
                        get: { settings.sourceTrackIDs.isEmpty || settings.sourceTrackIDs.contains(source.id) },
                        set: { on in
                            adjust(on ? "Caption \(source.name)" : "Don't Caption \(source.name)") { s in
                                var chosen = s.sourceTrackIDs.isEmpty ? audio.map(\.id) : s.sourceTrackIDs
                                if on { chosen.append(source.id) } else { chosen.removeAll { $0 == source.id } }
                                // Every track chosen is stored as "all", so new tracks are included.
                                s.sourceTrackIDs = Set(chosen) == Set(audio.map(\.id)) ? [] : chosen
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                }
            }

            InspectorSection(title: "Grouping", onReset: {
                adjust("Reset Grouping") { s in
                    let d = CaptionSettings()
                    s.maxWords = d.maxWords; s.maxDuration = d.maxDuration; s.pauseSplit = d.pauseSplit
                    s.minDuration = d.minDuration; s.splitsSentences = d.splitsSentences
                }
            }) {
                slider("Words", Double(settings.maxWords), 1...20, unit: "", digits: 0, action: "Change Words per Caption") {
                    $0.maxWords = Int($1.rounded())
                }
                slider("Longest", settings.maxDuration, CaptionSettings.durationRange, action: "Change Caption Length") { $0.maxDuration = $1 }
                slider("Pause", settings.pauseSplit, CaptionSettings.pauseRange, action: "Change Pause Split") { $0.pauseSplit = $1 }
                slider("Shortest", settings.minDuration, 0...3, action: "Change Shortest Caption") { $0.minDuration = $1 }
                Toggle("New caption at each sentence", isOn: Binding(get: { settings.splitsSentences },
                                                                     set: { on in adjust("Sentence Splits") { $0.splitsSentences = on } }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }

            InspectorSection(title: "Style", onReset: { adjust("Reset Caption Style") { $0.style = CaptionStyle() } }) {
                HStack(spacing: 6) {
                    ForEach(CaptionPreset.allCases) { preset in
                        Button(preset.title) { adjust("Caption Style: \(preset.title)") { $0.style = preset.style } }
                            .controlSize(.small)
                            .help("Use the \(preset.title) look (everything stays editable)")
                    }
                }
                FontPicker(postScriptName: settings.style.fontName) { name in adjust("Change Caption Font") { $0.style.fontName = name } }
                slider("Size", settings.style.size, 16...200, unit: " px", digits: 0, action: "Change Caption Size") { $0.style.size = $1 }
                ColorRow(title: "Color", color: settings.style.color) { c in adjust("Change Caption Color") { $0.style.color = c } }
                Toggle("Highlight the spoken word", isOn: Binding(get: { settings.style.highlightsWord },
                                                                   set: { on in adjust("Word Highlight") { $0.style.highlightsWord = on } }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                if settings.style.highlightsWord {
                    ColorRow(title: "Highlight color", color: settings.style.highlightColor) { c in adjust("Change Highlight Color") { $0.style.highlightColor = c } }
                }
                slider("Outline", settings.style.strokeWidth, 0...20, unit: " px", digits: 0, action: "Change Caption Outline") { $0.style.strokeWidth = $1 }
                if settings.style.strokeWidth > 0 {
                    ColorRow(title: "Outline color", color: settings.style.strokeColor) { c in adjust("Change Outline Color") { $0.style.strokeColor = c } }
                }
                Toggle("Box behind text", isOn: Binding(get: { settings.style.showsBox },
                                                        set: { on in adjust("Caption Box") { $0.style.showsBox = on } }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                if settings.style.showsBox {
                    ColorRow(title: "Box color", color: settings.style.boxColor) { c in adjust("Change Box Color") { $0.style.boxColor = c } }
                }
                Toggle("All caps", isOn: Binding(get: { settings.style.isUppercase },
                                                 set: { on in adjust("All Caps") { $0.style.isUppercase = on } }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                slider("Position", settings.style.position * 100, 5...95, unit: "%", digits: 0, action: "Move Captions") { $0.style.position = $1 / 100 }
            }

            InspectorSection(title: "Output") {
                Toggle("Burn captions into the picture", isOn: Binding(get: { settings.isBurnedIn },
                                                                       set: { on in adjust(on ? "Burn In Captions" : "Don't Burn In Captions") { $0.isBurnedIn = on } }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                Text("Captions show on the timeline either way; burned-in captions are drawn in the preview and exports.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Export Captions as .srt…") { exportSubtitles() }
                    .controlSize(.small)
                    .help("Saves the captions as a SubRip file, for YouTube or any player.")
            }
        }
    }
}
