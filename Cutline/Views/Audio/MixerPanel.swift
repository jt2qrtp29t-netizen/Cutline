import SwiftUI

/// The mixer: a strip per audio track (fader, pan, mute, solo, meter) and the master.
struct MixerPanel: View {
    let editor: EditorController

    var body: some View {
        let meters = editor.playback.meters
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Mixer")
                Spacer()
                Button {
                    editor.addTrack(.audio)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Add Audio Track")
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)

            GeometryReader { geometry in
                if MixerLayout.pinsMaster(width: geometry.size.width) {
                    // Wide enough: the strips scroll; master and loudness stay on the right.
                    HStack(spacing: 0) {
                        ScrollView(.horizontal) {
                            strips(meters).padding(8)
                        }
                        .scrollIndicators(.automatic)
                        Rectangle().fill(Theme.border).frame(width: 1)
                        masterAndLoudness(meters)
                    }
                } else {
                    // Narrow: everything scrolls together, so no strip is ever hidden.
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            strips(meters).padding(8)
                            Rectangle().fill(Theme.border).frame(width: 1)
                            masterAndLoudness(meters)
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
        .background(Theme.background)
        .onAppear { meters.beginWatching() }
        .onDisappear { meters.endWatching() }
    }
}

extension MixerPanel {
    private func strips(_ meters: MixerMeters) -> some View {
        HStack(spacing: 6) {
            ForEach(editor.audioTrackIndices, id: \.self) { index in
                let track = editor.state.tracks[index]
                MixerStrip(editor: editor, track: track, isActive: editor.state.isTrackActive(index),
                           reading: meters.tracks[track.id] ?? MixerMeters.Reading())
            }
        }
    }

    private func masterAndLoudness(_ meters: MixerMeters) -> some View {
        HStack(spacing: 0) {
            MasterStrip(editor: editor, reading: meters.master)
                .padding(8)
            LoudnessPanel(editor: editor, reading: meters.loudness)
                .padding(.vertical, 8)
                .padding(.trailing, 8)
        }
    }
}

/// How the mixer arranges itself in its width.
nonisolated enum MixerLayout {
    static let stripWidth = 84.0
    /// Master strip and loudness panel with their padding and the divider.
    static let masterAndLoudnessWidth = 84.0 + 16 + 150 + 8 + 1
    /// Master and loudness stay pinned only if at least one whole track strip fits beside them.
    static func pinsMaster(width: Double) -> Bool {
        width - masterAndLoudnessWidth >= stripWidth + 16
    }
}

/// One audio track's strip.
struct MixerStrip: View {
    let editor: EditorController
    let track: Track
    let isActive: Bool
    let reading: MixerMeters.Reading

    var body: some View {
        let volume = editor.trackAudioValue(.volume, track: track.id)
        let pan = editor.trackAudioValue(.pan, track: track.id)
        let isSelected = editor.selectedAudioTrackID == track.id
        VStack(spacing: 8) {
            Text(track.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            PanControl(pan: pan) { value in
                editor.adjustTrackAudio(.pan, to: value, track: track.id)
            } onEnd: {
                editor.endAudioAdjustment("Change Pan")
            } onReset: {
                editor.resetTrackAudio(.pan, track: track.id)
            }
            HStack(spacing: 4) {
                FaderControl(db: volume) { value in
                    editor.adjustTrackAudio(.volume, to: value, track: track.id)
                } onEnd: {
                    editor.endAudioAdjustment("Change Volume")
                } onReset: {
                    editor.resetTrackAudio(.volume, track: track.id)
                }
                MeterView(reading: reading, dimmed: !isActive) {
                    editor.playback.meters.resetClip(track: track.id)
                }
            }
            Text(FaderScale.label(volume) + " dB")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 4) {
                StripToggle(title: "M", isOn: track.isMuted, tint: Theme.mutedTrack, help: track.isMuted ? "Unmute" : "Mute") {
                    editor.toggleMute(track: track.id)
                }
                StripToggle(title: "S", isOn: track.isSoloed, tint: Theme.soloTrack, help: track.isSoloed ? "Unsolo" : "Solo (overrides mute)") {
                    editor.toggleSolo(track: track.id)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(width: 84)
        .background(isSelected ? Theme.mixerStripSelected : Theme.mixerStrip, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Theme.accent.opacity(0.6) : Theme.border)
        }
        .contentShape(.rect)
        .onTapGesture { editor.selectedAudioTrackID = track.id }
    }
}

/// The master bus: fader, meter, and the universal mute.
struct MasterStrip: View {
    let editor: EditorController
    let reading: MixerMeters.Reading

    var body: some View {
        let volume = editor.masterVolume()
        let settings = AppSettings.shared
        VStack(spacing: 8) {
            Text("Master")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer().frame(height: 22)
            HStack(spacing: 4) {
                FaderControl(db: volume) { value in
                    editor.adjustMasterVolume(to: value)
                } onEnd: {
                    editor.endAudioAdjustment("Change Master Volume")
                } onReset: {
                    editor.resetMasterVolume()
                }
                MeterView(reading: reading, dimmed: settings.isMuted) {
                    editor.playback.meters.resetClip(track: nil)
                }
            }
            Text(FaderScale.label(volume) + " dB")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            StripToggle(title: "M", isOn: settings.isMuted, tint: Theme.mutedTrack,
                        help: settings.isMuted ? "Unmute All Audio (⇧⌘M)" : "Mute All Audio (⇧⌘M)") {
                settings.isMuted.toggle()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(width: 84)
        .background(Theme.mixerStrip, in: .rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border) }
    }
}

/// A vertical fader on a console-style dB scale. Drag the cap (⌥ for fine control);
/// double-click to return to 0 dB.
struct FaderControl: View {
    let db: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    @State private var dragStart: Double?

    private static let capHeight: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - Self.capHeight, 1)
            let position = FaderScale.position(forDB: db)
            ZStack(alignment: .top) {
                // Scale ticks and the slot.
                Canvas { context, size in
                    for tick in FaderScale.ticks {
                        let y = Self.capHeight / 2 + travel * (1 - FaderScale.position(forDB: tick))
                        let width: CGFloat = tick == 0 ? 10 : 6
                        context.fill(Path(CGRect(x: 0, y: y - 0.5, width: width, height: 1)),
                                     with: .color(tick == 0 ? Theme.textSecondary : Theme.meterScale))
                    }
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.faderSlot)
                    .frame(width: 4)
                    .padding(.vertical, Self.capHeight / 2)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.faderCap)
                    .overlay { Rectangle().fill(Theme.faderCapLine).frame(height: 2) }
                    .frame(width: 26, height: Self.capHeight)
                    .shadow(color: Theme.shadow, radius: 2, y: 1)
                    .offset(y: travel * (1 - position))
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = position }
                        guard let start = dragStart else { return }
                        // ⌥ moves the cap 10× more finely, like the Color wheels.
                        let factor = Precision.factor >= 1 ? 1 : Precision.factor
                        let moved = start - Double(value.translation.height / travel) * factor
                        onChange(FaderScale.db(forPosition: moved))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onEnd()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
        }
        .frame(width: 30)
        .frame(minHeight: 140)
        .help("Drag to change the level (⌥ for fine control); double-click for 0 dB.")
    }
}

/// Peak meters for left and right, with peak hold and clip lights (click to clear).
struct MeterView: View {
    let reading: MixerMeters.Reading
    var dimmed = false
    let onResetClip: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                clipLight(reading.left.clipped)
                clipLight(reading.right.clipped)
            }
            .contentShape(.rect)
            .onTapGesture { onResetClip() }
            .help("Lights when the signal clips. Click to clear.")
            Canvas { context, size in
                let barWidth = (size.width - 2) / 2
                for (i, channel) in [reading.left, reading.right].enumerated() {
                    let x = CGFloat(i) * (barWidth + 2)
                    context.fill(Path(CGRect(x: x, y: 0, width: barWidth, height: size.height)), with: .color(Theme.meterTrack))
                    let level = MeterBallistics.fraction(channel.level)
                    let top = size.height * (1 - level)
                    // Green to −18 dB, yellow to −6 dB, red above.
                    for (from, to, color) in [(-60.0, -18.0, Theme.meterLow), (-18, -6, Theme.meterMid), (-6, 0, Theme.meterHigh)] {
                        let low = size.height * (1 - MeterBallistics.fraction(from))
                        let high = size.height * (1 - MeterBallistics.fraction(to))
                        let segmentTop = max(high, top)
                        if segmentTop < low {
                            context.fill(Path(CGRect(x: x, y: segmentTop, width: barWidth, height: low - segmentTop)),
                                         with: .color(color.opacity(dimmed ? 0.35 : 1)))
                        }
                    }
                    if channel.peakHold > MeterBallistics.floorDB {
                        let y = size.height * (1 - MeterBallistics.fraction(channel.peakHold))
                        context.fill(Path(CGRect(x: x, y: max(0, y - 1), width: barWidth, height: 2)), with: .color(Theme.textPrimary))
                    }
                }
            }
            .frame(width: 14)
        }
    }

    private func clipLight(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(on ? Theme.meterHigh : Theme.meterTrack)
            .frame(width: 6, height: 5)
    }
}

/// Stereo position: drag sideways (⌥ for fine control); double-click to center.
struct PanControl: View {
    let pan: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.faderSlot).frame(height: 4)
                    Rectangle().fill(Theme.meterScale).frame(width: 1, height: 8).offset(x: width / 2)
                    let x = width / 2 + CGFloat(pan) * (width / 2 - 5)
                    let fillStart = min(x, width / 2), fillEnd = max(x, width / 2)
                    Capsule().fill(Theme.accent).frame(width: max(fillEnd - fillStart, 1), height: 4).offset(x: fillStart)
                    Circle().fill(Theme.faderCap).frame(width: 10, height: 10).offset(x: x - 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStart == nil { dragStart = pan }
                            guard let start = dragStart else { return }
                            let factor = Precision.factor >= 1 ? 1 : Precision.factor
                            onChange((start + Double(value.translation.width / (width / 2)) * factor).clamped(to: -1...1))
                        }
                        .onEnded { _ in
                            dragStart = nil
                            onEnd()
                        }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
            }
            .frame(height: 14)
            Text(Self.label(pan))
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .help("Pan: drag sideways (⌥ for fine control); double-click to center.")
    }

    static func label(_ pan: Double) -> String {
        let amount = Int((abs(pan) * 100).rounded())
        if amount == 0 { return "C" }
        return pan < 0 ? "L\(amount)" : "R\(amount)"
    }
}

/// A small M or S button.
private struct StripToggle: View {
    let title: String
    let isOn: Bool
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isOn ? Theme.textOnAccent : Theme.textSecondary)
                .frame(width: 26, height: 20)
                .background(isOn ? tint : Theme.raised, in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
