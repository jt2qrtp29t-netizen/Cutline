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
                        InspectorSection(title: "Level") {
                            AudioParameterRow(editor: editor, ref: .volume(track.id))
                            AudioParameterRow(editor: editor, ref: .pan(track.id))
                        }
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
