import SwiftUI

/// The experiments registry: switch experiments on or off, add generators, apply effects.
struct LabsListSection: View {
    let session: PlaygroundSession
    private var sandbox: EditorController { session.editor }

    var body: some View {
        let visualSelection = sandbox.selection.filter { sandbox.state.track(ofClip: $0)?.kind.isVisual == true }
        InspectorSection(title: "Labs") {
            ForEach([Experiment.Kind.generator, .effect], id: \.self) { kind in
                SectionLabel(kind == .generator ? "Generators" : "Effects")
                ForEach(ExperimentRegistry.all.filter { $0.kind == kind }) { experiment in
                    let enabled = session.isExperimentEnabled(experiment.id)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: experiment.symbolName)
                            .font(.system(size: 12))
                            .foregroundStyle(enabled ? Theme.sandbox : Theme.textTertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(experiment.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                            Text(experiment.summary)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 4) {
                            Toggle("", isOn: Binding(get: { enabled }, set: { session.setExperiment(experiment.id, enabled: $0) }))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                                .help(enabled ? "Switch off in the Playground" : "Switch on")
                            if kind == .generator {
                                Button("Add") { sandbox.addGenerator(experiment.id) }
                                    .controlSize(.mini)
                                    .disabled(!enabled)
                                    .help("Add to the scratch timeline at the playhead")
                            } else {
                                Button("Apply") { sandbox.applyLabEffect(experiment.id, to: visualSelection) }
                                    .controlSize(.mini)
                                    .disabled(!enabled || visualSelection.isEmpty)
                                    .help(visualSelection.isEmpty ? "Select a clip first" : "Apply to the selected clips")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

/// The selected clip's Labs items (its generator and effects) with their parameters.
struct LabItemsSection: View {
    let session: PlaygroundSession
    private var sandbox: EditorController { session.editor }

    var body: some View {
        if let clip = sandbox.selectedClips.first, sandbox.selectedClips.count == 1,
           clip.generator != nil || !clip.labs.isEmpty {
            InspectorSection(title: "Labs on “\(clip.name)”") {
                if let generator = clip.generator {
                    LabItemEditor(session: session, clip: clip, effect: generator, isGenerator: true)
                }
                ForEach(clip.labs) { effect in
                    LabItemEditor(session: session, clip: clip, effect: effect, isGenerator: false)
                }
            }
            .disabled(clip.isLocked)
        }
    }
}

private struct LabItemEditor: View {
    let session: PlaygroundSession
    let clip: Clip
    let effect: LabEffect
    let isGenerator: Bool

    @State private var code = ""
    private var sandbox: EditorController { session.editor }

    var body: some View {
        let experiment = ExperimentRegistry.experiment(effect.experimentID)
        let error = LabStatus.shared.errors[effect.id]
        let switchedOff = !session.isExperimentEnabled(effect.experimentID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: experiment?.symbolName ?? "questionmark.square.dashed")
                    .foregroundStyle(Theme.sandbox)
                Text(experiment?.name ?? effect.experimentID)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(get: { effect.isEnabled }, set: { sandbox.setLabEnabled($0, effect.id, in: clip.id) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(effect.isEnabled ? "Turn off on this clip" : "Turn on")
                if !isGenerator {
                    Button {
                        sandbox.removeLabEffect(effect.id, from: clip.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Remove from this clip")
                }
            }
            if switchedOff {
                Text("Switched off in Labs: the clip shows without it.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            if let error {
                Label(error + (isGenerator ? "" : " The clip shows without this effect."), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.offlineBadge)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let experiment {
                ForEach(experiment.parameters) { parameter in
                    LabParameterRow(sandbox: sandbox, clip: clip, effect: effect, parameter: parameter)
                }
                if experiment.defaultSource != nil {
                    TextEditor(text: $code)
                        .font(.system(size: 10.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Theme.recessed, in: .rect(cornerRadius: 5))
                        .frame(height: 220)
                    HStack {
                        Button("Run Shader") { sandbox.setLabSource(code, effect.id, in: clip.id) }
                            .controlSize(.small)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(code == (effect.source ?? experiment.defaultSource))
                            .help("Compile and use this code (⌘↩)")
                        Button("Restore Example") {
                            code = experiment.defaultSource ?? ""
                            sandbox.setLabSource(code, effect.id, in: clip.id)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(8)
        .background(Theme.raised.opacity(0.6), in: .rect(cornerRadius: 6))
        .onAppear { code = effect.source ?? experiment?.defaultSource ?? "" }
        .onChange(of: effect.id) { code = effect.source ?? experiment?.defaultSource ?? "" }
    }
}

/// One Labs parameter: keyframe diamond, name, number field and precision slider.
private struct LabParameterRow: View {
    let sandbox: EditorController
    let clip: Clip
    let effect: LabEffect
    let parameter: ExperimentParameter

    var body: some View {
        let value = effect.value(of: parameter.id, default: parameter.defaultValue,
                                 atOffset: sandbox.playback.currentTime - clip.start)
        let keyed = sandbox.labKeyframeAtPlayhead(parameter.id, of: effect, in: clip) != nil
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button {
                    sandbox.toggleLabKeyframe(parameter.id, of: effect.id, in: clip.id)
                } label: {
                    KeyframeDiamond(isFilled: keyed, size: 10)
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(sandbox.playheadOffset(in: clip) == nil)
                .help(keyed ? "Remove keyframe at playhead" : "Add keyframe at playhead")
                Text(parameter.name)
                    .font(.system(size: 11))
                    .foregroundStyle(effect.isAnimated(parameter.id) ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                NumberField(value: value, range: parameter.range, displayScale: 1, unit: parameter.unit,
                            fractionDigits: parameter.range.upperBound - parameter.range.lowerBound > 10 ? 0 : 2,
                            step: (parameter.range.upperBound - parameter.range.lowerBound) / 100) {
                    sandbox.setLabValue($0, parameter: parameter.id, of: effect.id, in: clip.id)
                }
                .frame(width: 70)
            }
            PrecisionSlider(
                value: value, range: parameter.range,
                unitsPerPoint: (parameter.range.upperBound - parameter.range.lowerBound) / 250,
                onBegin: { sandbox.beginAdjustment() },
                onChange: { sandbox.setLabValue($0, parameter: parameter.id, of: effect.id, in: clip.id) },
                onEnd: { sandbox.endAdjustment("Change \(parameter.name)") }
            )
            .padding(.leading, 22)
        }
    }
}
