import SwiftUI

/// The master's loudness (EBU R128): momentary, short-term, integrated and true peak,
/// against the project's target; Normalize Project; and the master limiter.
struct LoudnessPanel: View {
    let editor: EditorController
    let reading: LoudnessReading

    var body: some View {
        let target = editor.state.audio.loudnessTarget
        let master = editor.state.audio.master
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Loudness")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    editor.resetLoudness()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Restart the integrated measurement")
            }
            row("Momentary", reading.momentary, unit: "LUFS", target: target)
            row("Short-term", reading.shortTerm, unit: "LUFS", target: target)
            row("Integrated", reading.integrated, unit: "LUFS", target: target, prominent: true)
            row("True peak", reading.truePeak, unit: "dBTP", target: nil, warnAbove: -1)

            Divider()
            HStack(spacing: 4) {
                targetMenu(target)
                NumberField(value: target, range: ProjectAudio.loudnessRange, unit: "", fractionDigits: 1, step: 0.5) {
                    editor.setLoudnessTarget($0)
                }
                .frame(width: 44)
                .help("Type any target in LUFS")
            }
            Button("Normalize Project") { editor.normalize(.project) }
                .controlSize(.small)
                .disabled(editor.audioActivity != nil || editor.state.duration == .zero)
                .help("Measures the whole mix and sets the master fader so it's at the target.")
            if let activity = editor.audioActivity {
                Label(activity, systemImage: "hourglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            } else if let message = editor.audioMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { editor.audioMessage = nil }
            }

            Divider()
            Toggle("Limiter", isOn: Binding(get: { master.limiterEnabled }, set: { editor.setMasterLimiter($0) }))
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Keeps the mix's peaks under the ceiling.")
            HStack {
                Text("Ceiling")
                Spacer()
                Text(String(format: "%.1f dB", master.ceilingDB).replacingOccurrences(of: "-", with: "−"))
                    .monospacedDigit()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(master.limiterEnabled ? Theme.textSecondary : Theme.textTertiary)
            PrecisionSlider(value: master.ceilingDB, range: MasterAudio.ceilingRange, unitsPerPoint: 0.05,
                            onBegin: { editor.beginAdjustment() },
                            onChange: { editor.adjustMasterCeiling(to: $0) },
                            onEnd: { editor.endAudioAdjustment("Change Limiter Ceiling") })
                .disabled(!master.limiterEnabled)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 150)
        .background(Theme.mixerStrip, in: .rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border) }
    }

    private func row(_ title: String, _ value: Double, unit: String, target: Double?, prominent: Bool = false,
                     warnAbove: Double? = nil) -> some View {
        let isOver = warnAbove.map { value > $0 } ?? false
        let near = target.map { abs(value - $0) <= 1 } ?? false
        return VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(LoudnessReading.label(value))
                    .font(.system(size: prominent ? 17 : 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isOver ? Theme.meterHigh : (near ? Theme.accent : Theme.textPrimary))
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func targetMenu(_ target: Double) -> some View {
        Menu {
            ForEach(ProjectAudio.loudnessTargets, id: \.value) { option in
                Button {
                    editor.setLoudnessTarget(option.value)
                } label: {
                    if option.value == target { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
            Divider()
            ForEach([-23.0, -20, -18, -12, -9], id: \.self) { value in
                Button(String(format: "%.0f LUFS", value).replacingOccurrences(of: "-", with: "−")) { editor.setLoudnessTarget(value) }
            }
        } label: {
            Text("Target")
                .font(.system(size: 10.5, weight: .medium))
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Normalize's target. −14 LUFS suits YouTube.")
    }
}
