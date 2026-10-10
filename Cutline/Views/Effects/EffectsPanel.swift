import SwiftUI

/// Left panel of the Effects tab: the selected clip's animatable parameters, each
/// with keyframe controls, plus details of the selected keyframe.
struct EffectsPanel: View {
    let editor: EditorController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Effects")
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let transition = editor.selectedTransition {
                        SelectedTransitionSection(editor: editor, id: transition)
                    }
                    TransitionsSection(editor: editor)
                    if let clip = editor.effectsClip {
                        InspectorSection(title: "Animate · \(clip.isText ? (clip.text?.string ?? "Text") : clip.name)") {
                            ForEach(AnimatableProperty.allCases) { property in
                                ParameterRow(editor: editor, clip: clip, property: property)
                            }
                            Text("◆ adds or removes a keyframe at the playhead; ◀︎ ▶︎ jump between keyframes. Changing an animated value sets a keyframe at the playhead.")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .disabled(clip.isLocked)
                        PresetsSection(editor: editor, clip: clip)
                            .disabled(clip.isLocked)
                        SelectedKeyframeSection(editor: editor, clip: clip)
                    } else {
                        InspectorSection(title: "Animate") {
                            Label("Select one video or text clip to animate it.", systemImage: "cursorarrow.click")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.background)
    }
}

private struct ParameterRow: View {
    let editor: EditorController
    let clip: Clip
    let property: AnimatableProperty

    var body: some View {
        let isCurrent = editor.effectsProperty == property
        let value = clip.value(of: property, at: editor.playback.currentTime)
        let keyframeHere = editor.keyframeAtPlayhead(property, in: clip)
        let animated = clip.isAnimated(property)
        let inside = editor.playheadOffset(in: clip) != nil

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                arrow("chevron.left", help: "Previous keyframe") {
                    editor.jumpToKeyframe(property, in: clip, next: false)
                }
                .disabled(!animated)
                Button {
                    editor.toggleKeyframe(property, in: clip)
                } label: {
                    KeyframeDiamond(isFilled: keyframeHere != nil, size: 11)
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!inside)
                .help(keyframeHere != nil ? "Remove keyframe at playhead" : "Add keyframe at playhead")
                arrow("chevron.right", help: "Next keyframe") {
                    editor.jumpToKeyframe(property, in: clip, next: true)
                }
                .disabled(!animated)

                Button {
                    editor.effectsProperty = property
                } label: {
                    Text(property.title)
                        .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Theme.accent : (animated ? Theme.textPrimary : Theme.textSecondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show \(property.title) in the curve editor")

                NumberField(value: value, range: property.range, displayScale: property.displayScale, unit: property.unit,
                            fractionDigits: property.fractionDigits, step: property.unitsPerPoint * 10) { newValue in
                    editor.setEffectValue(property, of: clip.id, to: newValue)
                }
                .frame(width: 78)
            }
            PrecisionSlider(
                value: value, range: property.sliderRange(for: editor.settings), unitsPerPoint: property.unitsPerPoint,
                onBegin: { editor.effectsProperty = property; editor.beginAdjustment() },
                onChange: { editor.setEffectValue(property, of: clip.id, to: $0) },
                onEnd: { editor.endAdjustment("Change \(property.title)") }
            )
            .padding(.leading, 62)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isCurrent ? Theme.accentMuted : Theme.raised.opacity(0), in: .rect(cornerRadius: 6))
        .contextMenu {
            Button("Show in Curve Editor") { editor.effectsProperty = property }
            Button("Remove All \(property.title) Keyframes", role: .destructive) {
                editor.clearAnimation(property, in: clip)
            }
            .disabled(!animated)
        }
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

/// Time, value and easing of the selected keyframe.
private struct SelectedKeyframeSection: View {
    let editor: EditorController
    let clip: Clip

    var body: some View {
        let refs = editor.selectedKeyframes.filter { $0.clipID == clip.id }
        if refs.count == 1, let ref = refs.first, let frame = editor.keyframe(ref) {
            InspectorSection(title: "Keyframe · \(ref.property.title)") {
                InspectorValueRow(title: "Time", value: Timecode.string(for: clip.start + frame.time, fps: editor.fps, alwaysShowHours: true))
                HStack(spacing: 8) {
                    InspectorLabel("Value")
                    NumberField(value: frame.value, range: ref.property.range, displayScale: ref.property.displayScale,
                                unit: ref.property.unit, fractionDigits: ref.property.fractionDigits,
                                step: ref.property.unitsPerPoint * 10) { value in
                        editor.dragKeyframe(ref, toTime: frame.time, value: value)
                        editor.endGesture("Change Keyframe Value")
                    }
                }
                HStack(spacing: 8) {
                    InspectorLabel("Easing")
                    Menu {
                        ForEach(Easing.presets, id: \.self) { easing in
                            Button(easing.title) { editor.setEasing(easing, for: ref) }
                        }
                        Button("Custom Curve") {
                            editor.setEasing(.bezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1), for: ref)
                        }
                    } label: {
                        Text(frame.easing.title)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                }
                Text("Easing shapes the motion from this keyframe to the next. Drag the handles in the curve editor for a custom curve.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Delete Keyframe", role: .destructive) { editor.deleteKeyframes([ref]) }
                    .controlSize(.small)
            }
        } else if refs.count > 1 {
            InspectorSection(title: "Keyframes") {
                Text("\(refs.count) keyframes selected. Drag to retime them together, or press Delete.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Button("Delete Keyframes", role: .destructive) { editor.deleteKeyframes(refs) }
                    .controlSize(.small)
            }
        }
    }
}

/// Animate in/out presets and gameplay presets. Each writes keyframes onto the clip.
private struct PresetsSection: View {
    let editor: EditorController
    let clip: Clip

    @AppStorage("presets.placementIsIn") private var placementIsIn = true
    @AppStorage("presets.duration") private var duration = 0.5
    @AppStorage("presets.gameplayDuration") private var gameplayDuration = 0.45

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 6)]

    var body: some View {
        InspectorSection(title: "Presets") {
            Picker("Placement", selection: $placementIsIn) {
                Text("Animate In").tag(true)
                Text("Animate Out").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            InspectorSlider(title: "Length", value: duration, range: 0.1...3, unit: "s", fractionDigits: 2,
                            unitsPerPoint: 0.01, onBegin: {}, onChange: { duration = $0 }, onEnd: {},
                            onSet: { duration = $0 })

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(AnimationPreset.inOutPresets) { preset in
                    let placement: AnimationPreset.Placement = placementIsIn ? .animateIn : .animateOut
                    PresetButton(preset: preset, title: preset.shortTitle,
                                 help: "\(preset.title(for: placement)) (\(String(format: "%.2f", duration)) s)") {
                        editor.applyPreset(preset, placement: placement, duration: duration, to: [clip.id])
                    }
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            SectionLabel("Gameplay · at playhead")
            InspectorSlider(title: "Length", value: gameplayDuration, range: 0.1...2, unit: "s", fractionDigits: 2,
                            unitsPerPoint: 0.01, onBegin: {}, onChange: { gameplayDuration = $0 }, onEnd: {},
                            onSet: { gameplayDuration = $0 })
            HStack(spacing: 6) {
                ForEach(AnimationPreset.gameplayPresets) { preset in
                    PresetButton(preset: preset, title: preset.shortTitle, help: "\(preset.title(for: .animateIn)) at the playhead") {
                        editor.applyPreset(preset, placement: .at(.zero), duration: gameplayDuration, to: [clip.id])
                    }
                }
            }
            .disabled(editor.playheadOffset(in: clip) == nil)

            Text("Presets add ordinary keyframes on top of what the clip already does, so you can fine-tune them afterwards.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PresetButton: View {
    let preset: AnimationPreset
    let title: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(isHovering ? Theme.raisedHover : Theme.raised, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}
