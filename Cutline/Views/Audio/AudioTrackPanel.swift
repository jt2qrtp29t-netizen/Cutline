import SwiftUI

/// The Audio tab's right panel: the selected track's level, pan and effect chain.
struct AudioTrackPanel: View {
    let editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Track")
                Spacer()
                if let track = editor.audioSettingsTrack {
                    trackPicker(track)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            if let track = editor.audioSettingsTrack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let clip = editor.audioClip {
                            AudioClipSection(editor: editor, clip: clip)
                                .id(clip.id)
                        }
                        InspectorSection(title: "Level") {
                            AudioParameterRow(editor: editor, ref: .volume(track.id))
                            AudioParameterRow(editor: editor, ref: .pan(track.id))
                            HStack {
                                Button("Normalize Track") { editor.normalize(.track(track.id)) }
                                    .controlSize(.small)
                                    .disabled(editor.audioActivity != nil || track.clips.isEmpty)
                                    .help("Measures this track as it sounds (effects included) and sets its fader to the project's loudness target.")
                                Text("to " + String(format: "%.1f LUFS", editor.state.audio.loudnessTarget).replacingOccurrences(of: "-", with: "−"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        DuckingSection(editor: editor, track: track)
                        chainHeader(track)
                        if track.audio.effects.isEmpty {
                            Text("No effects. Add one below, or start from a preset.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 4)
                        }
                        ForEach(Array(track.audio.effects.enumerated()), id: \.element.id) { index, effect in
                            EffectCard(editor: editor, track: track, effect: effect,
                                       isFirst: index == 0, isLast: index == track.audio.effects.count - 1)
                        }
                        addEffectMenu(track)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .disabled(track.isLocked)
            } else {
                ContentUnavailableView("No Audio Tracks", systemImage: "waveform",
                                       description: Text("Add an audio track in the mixer."))
            }
        }
        .background(Theme.background)
    }

    private func trackPicker(_ track: Track) -> some View {
        Menu {
            ForEach(editor.audioTrackIndices, id: \.self) { index in
                let t = editor.state.tracks[index]
                Button(t.name) { editor.selectedAudioTrackID = t.id }
            }
        } label: {
            Text(track.name)
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private func chainHeader(_ track: Track) -> some View {
        HStack {
            Text("EFFECTS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            if let preset = track.audio.presetName {
                Text("from “\(preset)”")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Menu("Presets") {
                ForEach(AudioPreset.all) { preset in
                    Button {
                        editor.applyPreset(preset, to: track.id)
                    } label: {
                        Text(preset.name)
                        Text(preset.summary)
                    }
                }
                Divider()
                Button("Remove All Effects", role: .destructive) { editor.clearEffects(of: track.id) }
                    .disabled(track.audio.effects.isEmpty)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Replace this track's effects with a preset. Presets set ordinary values you can keep editing.")
        }
        .padding(.horizontal, 4)
    }

    private func addEffectMenu(_ track: Track) -> some View {
        Menu {
            ForEach(AudioEffectKind.allCases) { kind in
                Button {
                    editor.addEffect(kind, to: track.id)
                } label: {
                    Label(kind.title, systemImage: kind.symbolName)
                }
            }
        } label: {
            Label("Add Effect", systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }
}

/// One effect in the chain: name, bypass, order and its parameters.
struct EffectCard: View {
    let editor: EditorController
    let track: Track
    let effect: AudioEffect
    let isFirst: Bool
    let isLast: Bool

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                Image(systemName: effect.kind.symbolName)
                    .font(.system(size: 10))
                    .foregroundStyle(effect.isBypassed ? Theme.textTertiary : Theme.accent)
                Text(effect.kind.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(effect.isBypassed ? Theme.textTertiary : Theme.textPrimary)
                    .help(effect.kind.summary)
                Spacer()
                iconButton("chevron.up", help: "Move Earlier") { editor.moveEffect(effect.id, by: -1, in: track.id) }
                    .disabled(isFirst)
                iconButton("chevron.down", help: "Move Later") { editor.moveEffect(effect.id, by: 1, in: track.id) }
                    .disabled(isLast)
                iconButton("power", help: effect.isBypassed ? "Turn On" : "Bypass", tint: effect.isBypassed ? Theme.textTertiary : Theme.accent) {
                    editor.setBypassed(!effect.isBypassed, effect: effect.id, in: track.id)
                }
                iconButton("xmark", help: "Remove") { editor.removeEffect(effect.id, from: track.id) }
            }
            if isExpanded {
                ForEach(effect.kind.parameters) { parameter in
                    AudioParameterRow(editor: editor, ref: .effect(effect, parameter, track: track.id))
                }
                .opacity(effect.isBypassed ? 0.5 : 1)
            }
        }
        .padding(8)
        .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 6))
    }

    private func iconButton(_ symbol: String, help: String, tint: Color = Theme.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A keyframable track or effect parameter: previous/next keyframe, the diamond (add or
/// remove a keyframe at the playhead), the value, and a slider (on a log scale for
/// frequencies and times). Double-click the name to reset.
struct AudioParameterRow: View {
    let editor: EditorController
    let ref: TrackParameterRef

    var body: some View {
        let parameter = ref.parameter
        let value = editor.trackParameterValue(ref)
        let keyframeHere = editor.trackKeyframeAtPlayhead(ref)
        let animated = !editor.trackKeyframes(ref).isEmpty
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                arrow("chevron.left", help: "Previous keyframe") { editor.jumpToTrackKeyframe(ref, next: false) }
                    .disabled(!animated)
                Button {
                    editor.toggleTrackKeyframe(ref)
                } label: {
                    KeyframeDiamond(isFilled: keyframeHere != nil, size: 11)
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(keyframeHere != nil ? "Remove keyframe at playhead" : "Add keyframe at playhead")
                arrow("chevron.right", help: "Next keyframe") { editor.jumpToTrackKeyframe(ref, next: true) }
                    .disabled(!animated)
                Text(parameter.title)
                    .font(.system(size: 11))
                    .foregroundStyle(animated ? Theme.textPrimary : Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { editor.setTrackParameter(ref, to: parameter.defaultValue) }
                    .help("Double-click to reset")
                Text(label(value))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 78, alignment: .trailing)
            }
            PrecisionSlider(
                value: parameter.position(of: value), range: 0...1, unitsPerPoint: 0.004,
                onBegin: { editor.beginAdjustment() },
                onChange: { editor.adjustTrackParameter(ref, to: parameter.value(atPosition: $0)) },
                onEnd: { editor.endAudioAdjustment("Change \(parameter.title)") }
            )
            .padding(.leading, 62)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reset \(parameter.title)") { editor.setTrackParameter(ref, to: parameter.defaultValue) }
            Button("Remove All \(parameter.title) Keyframes", role: .destructive) { editor.clearTrackKeyframes(ref) }
                .disabled(!animated)
        }
    }

    private func label(_ value: Double) -> String {
        if ref.parameter.id == AudioParameter.pan.id && ref.effectID == nil { return PanControl.label(value) }
        if ref.parameter.id == AudioParameter.volume.id && ref.effectID == nil { return FaderScale.label(value) + " dB" }
        return ref.parameter.label(value)
    }

    private func arrow(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Ducking: a "game" track goes down while a "voice" track is talking.
private struct DuckingSection: View {
    let editor: EditorController
    let track: Track

    var body: some View {
        let ducking = editor.state.audio.ducking
        let tracks = editor.audioTrackIndices.map { editor.state.tracks[$0] }
        InspectorSection(title: "Ducking") {
            if let ducking {
                Toggle("Duck the game track under the voice", isOn: Binding(get: { ducking.isEnabled },
                                                                            set: { editor.setDuckingEnabled($0) }))
                    .font(.system(size: 11))
                trackRow("Voice", selection: ducking.voiceTrackID, tracks: tracks) { editor.setDucking(voice: $0, game: ducking.gameTrackID) }
                trackRow("Game", selection: ducking.gameTrackID, tracks: tracks) { editor.setDucking(voice: ducking.voiceTrackID, game: $0) }
                slider("Threshold", \.thresholdDB, DuckingSettings.thresholdRange, "%.0f dB", ducking)
                slider("Amount", \.amountDB, DuckingSettings.amountRange, "%.0f dB", ducking)
                slider("Attack", \.attackMS, DuckingSettings.attackRange, "%.0f ms", ducking)
                slider("Release", \.releaseMS, DuckingSettings.releaseRange, "%.0f ms", ducking)
                HStack {
                    if DuckingCenter.shared.isAnalyzing(editor.state) {
                        ProgressView().controlSize(.mini)
                        Text("Analyzing the voice…")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("Worked out from the voice ahead of time, so every playback and export ducks the same way.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { editor.removeDucking() }
                        .controlSize(.small)
                }
            } else if tracks.count >= 2 {
                Text("Turn a game or music track down automatically while someone talks.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Menu("Duck Another Track Under \(track.name)") {
                    ForEach(tracks.filter { $0.id != track.id }) { other in
                        Button(other.name) { editor.setDucking(voice: track.id, game: other.id) }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            } else {
                Text("Add a second audio track to duck one under the other.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func trackRow(_ title: String, selection: UUID, tracks: [Track], set: @escaping (UUID) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 62, alignment: .leading)
            Menu(tracks.first { $0.id == selection }?.name ?? "—") {
                ForEach(tracks) { other in
                    Button {
                        set(other.id)
                    } label: {
                        if other.id == selection { Label(other.name, systemImage: "checkmark") } else { Text(other.name) }
                    }
                }
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<DuckingSettings, Double>, _ range: ClosedRange<Double>,
                        _ format: String, _ ducking: DuckingSettings) -> some View {
        let value = ducking[keyPath: keyPath]
        let isLog = range.lowerBound > 0
        let position = isLog ? log(value / range.lowerBound) / log(range.upperBound / range.lowerBound)
            : (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: format, value).replacingOccurrences(of: "-", with: "−"))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
            PrecisionSlider(value: position, range: 0...1, unitsPerPoint: 0.004,
                            onBegin: { editor.beginAdjustment() },
                            onChange: { p in
                                let v = isLog ? range.lowerBound * pow(range.upperBound / range.lowerBound, p)
                                    : range.lowerBound + p * (range.upperBound - range.lowerBound)
                                editor.adjustDucking(keyPath, to: v, in: range)
                            },
                            onEnd: { editor.endAudioAdjustment("Change Ducking") })
        }
    }
}

/// The selected audio clip: volume and pan (keyframable), clip gain, fades and pitch.
private struct AudioClipSection: View {
    let editor: EditorController
    let clip: Clip

    var body: some View {
        InspectorSection(title: "Clip · \(clip.name)") {
            ParameterRow(editor: editor, clip: clip, property: .volume)
            ParameterRow(editor: editor, clip: clip, property: .pan)
            slider("Gain", value: clip.gainDB, range: -24...24, unit: " dB", digits: 1, step: 0.05) { $0.gainDB = $1 }
            fadeRow("In", .leading, clip.fadeIn)
            fadeRow("Out", .trailing, clip.fadeOut)
            slider("Semitones", value: clip.pitchSemitones, range: -24...24, unit: "", digits: 0, step: 0.1) { $0.pitchSemitones = $1.rounded() }
            slider("Cents", value: clip.pitchCents, range: -100...100, unit: "", digits: 0, step: 0.5) { $0.pitchCents = $1.rounded() }
            HStack {
                Button("Normalize Clip") { editor.normalize(.clip(clip.id)) }
                    .controlSize(.small)
                    .disabled(editor.audioActivity != nil)
                Text("to " + String(format: "%.1f LUFS", editor.state.audio.loudnessTarget).replacingOccurrences(of: "-", with: "−"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if clip.speed != 1 {
                    Text("Speed \(Int((clip.speed * 100).rounded()))%")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .disabled(editor.state.isClipLocked(clip.id))
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, unit: String, digits: Int, step: Double,
                        apply: @escaping (inout Clip, Double) -> Void) -> some View {
        let id = clip.id
        return InspectorSlider(title: title, value: value, range: range, unit: unit, fractionDigits: digits, unitsPerPoint: step,
                               onBegin: editor.beginAdjustment,
                               onChange: { v in editor.adjustClip(id, actionName: "Change \(title)") { apply(&$0, v) } },
                               onEnd: { editor.endAdjustment("Change \(title)") },
                               onSet: { v in editor.adjustClip(id, actionName: "Change \(title)") { apply(&$0, v) } })
    }

    private func fadeRow(_ title: String, _ edge: ClipEdge, _ fade: AudioFade) -> some View {
        let id = clip.id
        return VStack(alignment: .leading, spacing: 4) {
            InspectorSlider(title: "Fade \(title)", value: fade.duration.seconds, range: 0...max(clip.duration.seconds, 0.01),
                            unit: " s", fractionDigits: 2, unitsPerPoint: 0.01,
                            onBegin: editor.beginAdjustment,
                            onChange: { editor.adjustFade(edge, of: id, to: Time(seconds: $0)) },
                            onEnd: { editor.endAudioAdjustment("Change Fade \(title)") },
                            onSet: { editor.setFade(edge, of: [id], to: Time(seconds: $0)) })
            Picker("Curve", selection: Binding(get: { fade.curve }, set: { editor.setFadeCurve(edge, of: [id], to: $0) })) {
                ForEach(FadeCurve.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!fade.isActive)
        }
    }
}
