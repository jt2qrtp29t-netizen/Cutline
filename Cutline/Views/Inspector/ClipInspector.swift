import SwiftUI

/// Adjustments for the selected clip. Video clips get zoom, crop, compositing,
/// speed and color; audio clips get volume and speed.
struct ClipInspector: View {
    let editor: EditorController
    let clip: Clip
    let kind: TrackKind

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private static let zoomRange = 0.1...4.0
    private static let zoomStep = 1.1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSection(title: "\(kind.title) Clip") {
                TextField("Clip name", text: $name)
                    .font(.system(size: 12, weight: .medium))
                    .themedField()
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                InspectorValueRow(title: "Start", value: timecode(clip.start))
                InspectorValueRow(title: "Duration", value: timecode(clip.duration))
                InspectorValueRow(title: "Source in", value: timecode(clip.sourceStart))
                if let media = editor.state.mediaItem(clip.mediaID) {
                    InspectorValueRow(title: "Media", value: media.hasVideo ? "\(media.name) · \(media.width)×\(media.height)" : media.name)
                }
            }

            if clip.isLocked {
                Label("This clip is locked. Unlock it from its right-click menu to edit.", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            if clip.linkID != nil {
                Label("Linked: moves, trims, cuts and speed changes apply to linked clips too.", systemImage: "link")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            Group {
                if kind == .video {
                    videoSections
                } else {
                    audioSections
                }

                InspectorSection(title: "Speed", onReset: {
                    editor.setSpeed(1, for: clip.id)
                }) {
                    InspectorSlider(
                        title: "Speed", value: clip.speed, range: 0.25...4, displayScale: 100, unit: "%",
                        unitsPerPoint: 0.005,
                        onBegin: editor.beginAdjustment,
                        onChange: { editor.setSpeed($0, for: clip.id) },
                        onEnd: { editor.endAdjustment("Change Speed") },
                        onSet: { editor.setSpeed($0, for: clip.id) }
                    )
                }
            }
            .disabled(clip.isLocked)
        }
        .onAppear { name = clip.name }
        .onChange(of: clip.name) { _, newValue in if !nameFocused { name = newValue } }
    }

    @ViewBuilder
    private var videoSections: some View {
        InspectorSection(title: "Transform", onReset: {
            editor.adjustClip(clip.id, actionName: "Reset Transform") { $0.transform = .identity }
        }) {
            // 0.1 % per point dragged (0.01 % with ⌥).
            slider("Zoom", \.transform.scale, range: Self.zoomRange, displayScale: 100, unit: "%",
                   fractionDigits: 1, unitsPerPoint: 0.001, action: "Zoom Clip")
            HStack(spacing: 6) {
                Button { zoom(by: 1 / Self.zoomStep) } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass").frame(maxWidth: .infinity)
                }
                Button { zoom(by: Self.zoomStep) } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.small)
            .buttonStyle(.glass)

            Rectangle().fill(Theme.border).frame(height: 1)
            // 1 px per point dragged (0.1 px with ⌥). The second field is the end
            // position; unlock it to move the clip across its duration.
            positionRow("Position X", start: \.transform.positionX, end: \.transform.endPositionX,
                        limit: Double(editor.settings.width))
            positionRow("Position Y", start: \.transform.positionY, end: \.transform.endPositionY,
                        limit: Double(editor.settings.height))
            Text(clip.transform.isAnimated
                 ? "Moves from the first value at the clip's start to the second at its end."
                 : "Unlock 🔒 to set an end position and move the clip over its duration.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 6) {
                flipButton("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                           isOn: clip.transform.flipHorizontal) { $0.transform.flipHorizontal.toggle() }
                flipButton("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                           isOn: clip.transform.flipVertical) { $0.transform.flipVertical.toggle() }
            }
            // 0.25° per point dragged (0.025° with ⌥).
            slider("Yaw", \.transform.yaw, range: -89...89, unit: "°", fractionDigits: 1,
                   unitsPerPoint: 0.25, action: "Change Yaw")
            slider("Pitch", \.transform.pitch, range: -89...89, unit: "°", fractionDigits: 1,
                   unitsPerPoint: 0.25, action: "Change Pitch")
            Text("Hold ⌥ while dragging for fine control, ⇧ for coarse.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }

        InspectorSection(title: "Crop", onReset: {
            editor.adjustClip(clip.id, actionName: "Reset Crop") { $0.crop = .none }
        }) {
            cropSlider("Top", \.top, opposite: \.bottom)
            cropSlider("Bottom", \.bottom, opposite: \.top)
            cropSlider("Left", \.left, opposite: \.right)
            cropSlider("Right", \.right, opposite: \.left)
        }

        InspectorSection(title: "Compositing", onReset: {
            editor.adjustClip(clip.id, actionName: "Reset Opacity") { $0.opacity = 1 }
        }) {
            slider("Opacity", \.opacity, range: 0...1, displayScale: 100, unit: "%", action: "Change Opacity")
        }

        InspectorSection(title: "Color", onReset: {
            editor.adjustClip(clip.id, actionName: "Reset Color") { $0.color = .neutral }
        }) {
            slider("Exposure", \.color.exposure, range: -3...3, fractionDigits: 2, action: "Change Exposure")
            slider("Brightness", \.color.brightness, range: -0.5...0.5, displayScale: 100, action: "Change Brightness")
            slider("Contrast", \.color.contrast, range: 0.25...2, displayScale: 100, unit: "%", action: "Change Contrast")
            slider("Saturation", \.color.saturation, range: 0...2, displayScale: 100, unit: "%", action: "Change Saturation")
        }
    }

    @ViewBuilder
    private var audioSections: some View {
        InspectorSection(title: "Audio", onReset: {
            editor.adjustClip(clip.id, actionName: "Reset Audio") { clip in
                clip.volume = 1
                clip.pan = 0
            }
        }) {
            slider("Volume", \.volume, range: 0...2, displayScale: 100, unit: "%", unitsPerPoint: 0.005,
                   action: "Change Volume")
            slider("Pan", \.pan, range: -1...1, displayScale: 100, unitsPerPoint: 0.005, action: "Change Pan")
            HStack {
                Text("L").frame(width: 68, alignment: .leading)
                Spacer()
                Text(panLabel)
                Spacer()
                Text("R")
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
        }

        InspectorSection(title: "Pitch", onReset: {
            editor.adjustClip(clip.id, actionName: "Reset Pitch") { clip in
                clip.pitchSemitones = 0
                clip.pitchCents = 0
            }
        }) {
            // Semitones move in whole steps; cents give the fine tuning.
            roundedSlider("Semitones", \.pitchSemitones, range: -24...24, unitsPerPoint: 0.1, step: 1,
                          action: "Change Pitch")
            roundedSlider("Cents", \.pitchCents, range: -100...100, unitsPerPoint: 0.5, step: 1,
                          action: "Change Pitch")
            Text("Pitch changes don't affect speed; speed changes keep the pitch.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var panLabel: String {
        let percent = Int((clip.pan * 100).rounded())
        return percent == 0 ? "Center" : (percent < 0 ? "\(-percent)% L" : "\(percent)% R")
    }

    /// Slider whose value snaps to multiples of `step` (e.g. whole semitones).
    private func roundedSlider(
        _ title: String,
        _ keyPath: WritableKeyPath<Clip, Double>,
        range: ClosedRange<Double>,
        unitsPerPoint: Double,
        step: Double,
        action: String
    ) -> some View {
        let id = clip.id
        let set: (Double) -> Void = { value in
            let snapped = (value / step).rounded() * step
            editor.adjustClip(id, actionName: action) { $0[keyPath: keyPath] = snapped }
        }
        return InspectorSlider(
            title: title, value: clip[keyPath: keyPath], range: range, unitsPerPoint: unitsPerPoint,
            onBegin: editor.beginAdjustment, onChange: set, onEnd: { editor.endAdjustment(action) }, onSet: set
        )
    }

    private func positionRow(
        _ title: String,
        start: WritableKeyPath<Clip, Double>,
        end: WritableKeyPath<Clip, Double?>,
        limit: Double
    ) -> some View {
        let id = clip.id
        let action = "Move Clip Position"
        return AnimatedValueRow(
            title: title,
            start: clip[keyPath: start],
            end: clip[keyPath: end],
            range: -limit...limit,
            onBegin: editor.beginAdjustment,
            onEnd: { editor.endAdjustment(action) },
            onChangeStart: { value in editor.adjustClip(id, actionName: action) { $0[keyPath: start] = value } },
            onChangeEnd: { value in editor.adjustClip(id, actionName: action) { $0[keyPath: end] = value } },
            onSetStart: { value in editor.adjustClip(id, actionName: action) { $0[keyPath: start] = value } },
            onSetEnd: { value in
                editor.adjustClip(id, actionName: value == nil ? "Lock End Position" : action) { $0[keyPath: end] = value }
            }
        )
    }

    private func flipButton(_ title: String, systemImage: String, isOn: Bool,
                            toggle: @escaping (inout Clip) -> Void) -> some View {
        Button {
            editor.adjustClip(clip.id, actionName: title, toggle)
        } label: {
            Label(title.replacingOccurrences(of: "Flip ", with: ""), systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? Theme.textOnAccent : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(isOn ? Theme.accent : Theme.recessed, in: .rect(cornerRadius: Theme.Metrics.controlCornerRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// Zoom buttons step 10 %; with ⌥ they step 1 %.
    private func zoom(by factor: Double) {
        let step = pow(factor, Precision.factor)
        let scale = (clip.transform.scale * step).clamped(to: Self.zoomRange)
        editor.adjustClip(clip.id, actionName: "Zoom Clip") { $0.transform.scale = scale }
    }

    private func slider(
        _ title: String,
        _ keyPath: WritableKeyPath<Clip, Double>,
        range: ClosedRange<Double>,
        displayScale: Double = 1,
        unit: String = "",
        fractionDigits: Int = 0,
        unitsPerPoint: Double? = nil,
        action: String
    ) -> some View {
        let id = clip.id
        return InspectorSlider(
            title: title,
            value: clip[keyPath: keyPath],
            range: range,
            displayScale: displayScale,
            unit: unit,
            fractionDigits: fractionDigits,
            unitsPerPoint: unitsPerPoint,
            onBegin: editor.beginAdjustment,
            onChange: { value in editor.adjustClip(id, actionName: action) { $0[keyPath: keyPath] = value } },
            onEnd: { editor.endAdjustment(action) },
            onSet: { value in editor.adjustClip(id, actionName: action) { $0[keyPath: keyPath] = value } }
        )
    }

    /// A crop edge, limited so the opposite edges always leave some of the image visible.
    private func cropSlider(
        _ title: String,
        _ edge: WritableKeyPath<CropInsets, Double>,
        opposite: KeyPath<CropInsets, Double>
    ) -> some View {
        let id = clip.id
        let apply: (Double) -> Void = { value in
            editor.adjustClip(id, actionName: "Crop Clip") { clip in
                let limit = 1 - CropInsets.minimumVisible - clip.crop[keyPath: opposite]
                clip.crop[keyPath: edge] = min(value, max(limit, 0))
            }
        }
        return InspectorSlider(
            title: title,
            value: clip.crop[keyPath: edge],
            range: 0...0.95,
            displayScale: 100,
            unit: "%",
            fractionDigits: 1,
            unitsPerPoint: 0.001,
            onBegin: editor.beginAdjustment,
            onChange: apply,
            onEnd: { editor.endAdjustment("Crop Clip") },
            onSet: apply
        )
    }

    private func timecode(_ time: Time) -> String {
        Timecode.string(for: time, fps: editor.fps, alwaysShowHours: true)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { name = clip.name; return }
        guard trimmed != clip.name else { return }
        editor.adjustClip(clip.id, actionName: "Rename Clip") { $0.name = trimmed }
    }
}
