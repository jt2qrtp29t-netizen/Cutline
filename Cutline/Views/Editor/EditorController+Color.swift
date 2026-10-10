import AppKit
import UniformTypeIdentifiers

// MARK: Color grading

extension EditorController {
    /// Sets several grade values at once (e.g. a wheel's x and y), as one edit. Animated
    /// values get a keyframe at the playhead; others change their plain value. While a
    /// live edit is open (a drag), every call replaces the previous one, so one drag is
    /// one undo step.
    func setGradeValues(_ values: [AnimatableProperty: Double], of clipID: UUID, actionName: String) {
        guard let clip = state.clip(clipID), !state.isClipLocked(clipID) else { NSSound.beep(); return }
        let offset = playheadOffset(in: clip)
        let apply: (inout ProjectState) -> Void = { state in
            state.updateClip(clipID) { clip in
                for (property, value) in values {
                    let value = value.clamped(to: property.range)
                    if clip.isAnimated(property) {
                        if let offset { clip.animation.setKeyframe(property, at: offset, value: value) }
                    } else {
                        clip[keyPath: property.keyPath] = value
                    }
                }
            }
        }
        if store.isLiveEditing {
            store.liveEdit(apply)
        } else {
            store.edit(actionName, apply)
        }
    }
}

/// The four primary color wheels.
enum GradeWheel: String, CaseIterable, Identifiable {
    case lift, gamma, gain, offset

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var help: String {
        switch self {
        case .lift: "Shadows: tint and raise or lower the blacks."
        case .gamma: "Midtones: tint and brighten or darken the middle of the range."
        case .gain: "Highlights: tint and raise or lower the whites."
        case .offset: "Everything: shifts the whole tonal range evenly."
        }
    }

    var keyPath: WritableKeyPath<ColorGrade, ColorWheel> {
        switch self {
        case .lift: \.lift
        case .gamma: \.gamma
        case .gain: \.gain
        case .offset: \.offset
        }
    }

    /// Puck x, puck y and master.
    var properties: (x: AnimatableProperty, y: AnimatableProperty, master: AnimatableProperty) {
        switch self {
        case .lift: (.liftX, .liftY, .liftMaster)
        case .gamma: (.gammaX, .gammaY, .gammaMaster)
        case .gain: (.gainX, .gainY, .gainMaster)
        case .offset: (.offsetX, .offsetY, .offsetMaster)
        }
    }

    var allProperties: [AnimatableProperty] { [properties.x, properties.y, properties.master] }
}

/// Groups of grade controls that reset together.
enum GradeSection: String, CaseIterable {
    case wheels, basic, curves, hueSaturation, lut

    var title: String {
        switch self {
        case .wheels: "Primaries"
        case .basic: "Basic"
        case .curves: "Curves"
        case .hueSaturation: "Hue vs Saturation"
        case .lut: "LUT"
        }
    }

    var properties: [AnimatableProperty] {
        switch self {
        case .wheels: GradeWheel.allCases.flatMap(\.allProperties)
        case .basic: [.exposure, .brightness, .contrast, .saturation, .temperature, .tint, .highlights, .shadows]
        case .curves, .hueSaturation: []
        case .lut: [.lutIntensity]
        }
    }

    /// Puts this section of a grade back to neutral.
    func reset(_ grade: inout ColorGrade) {
        let neutral = ColorGrade.neutral
        switch self {
        case .wheels:
            grade.lift = neutral.lift
            grade.gamma = neutral.gamma
            grade.gain = neutral.gain
            grade.offset = neutral.offset
        case .basic:
            grade.exposure = neutral.exposure
            grade.brightness = neutral.brightness
            grade.contrast = neutral.contrast
            grade.saturation = neutral.saturation
            grade.temperature = neutral.temperature
            grade.tint = neutral.tint
            grade.highlights = neutral.highlights
            grade.shadows = neutral.shadows
        case .curves:
            grade.curves = neutral.curves
        case .hueSaturation:
            grade.hueSaturation = neutral.hueSaturation
        case .lut:
            grade.lut = nil
            grade.lutIntensity = neutral.lutIntensity
        }
    }
}

extension EditorController {
    /// The clip the Color tab grades: one selected video or text clip.
    var colorClip: Clip? { effectsClip }

    /// A wheel's values at the playhead.
    func wheel(_ wheel: GradeWheel, of clip: Clip) -> ColorWheel {
        clip.grade(at: playback.currentTime)[keyPath: wheel.keyPath]
    }

    /// Whether any of a wheel's values has a keyframe under the playhead.
    func wheelHasKeyframeHere(_ wheel: GradeWheel, in clip: Clip) -> Bool {
        wheel.allProperties.contains { keyframeAtPlayhead($0, in: clip) != nil }
    }

    /// Adds keyframes for the whole wheel (puck and master) at the playhead, or removes them.
    func toggleWheelKeyframe(_ wheel: GradeWheel, in clip: Clip) {
        guard let offset = playheadOffset(in: clip), !state.isClipLocked(clip.id) else { NSSound.beep(); return }
        let remove = wheelHasKeyframeHere(wheel, in: clip)
        let values = self.wheel(wheel, of: clip)
        let existing = wheel.allProperties.compactMap { property in keyframeAtPlayhead(property, in: clip).map { (property, $0.id) } }
        store.edit(remove ? "Remove \(wheel.title) Keyframe" : "Add \(wheel.title) Keyframe") { state in
            state.updateClip(clip.id) { clip in
                if remove {
                    for (property, id) in existing { clip.animation.removeKeyframe(property, id: id) }
                } else {
                    clip.animation.setKeyframe(wheel.properties.x, at: offset, value: values.x)
                    clip.animation.setKeyframe(wheel.properties.y, at: offset, value: values.y)
                    clip.animation.setKeyframe(wheel.properties.master, at: offset, value: values.master)
                }
            }
        }
    }

    /// Resets a section of the grade, including its keyframes. Nil resets the whole grade.
    func resetGrade(_ section: GradeSection?, of clipID: UUID) {
        guard !state.isClipLocked(clipID) else { NSSound.beep(); return }
        let sections = section.map { [$0] } ?? GradeSection.allCases
        let name = section.map { "Reset \($0.title)" } ?? "Reset Grade"
        store.edit(name) { state in
            state.updateClip(clipID) { clip in
                for section in sections {
                    section.reset(&clip.color)
                    for property in section.properties { clip.animation.keyframes[property] = nil }
                }
            }
        }
    }

    /// Resets one wheel (double-click), including its keyframes.
    func resetWheel(_ wheel: GradeWheel, of clipID: UUID) {
        guard !state.isClipLocked(clipID) else { NSSound.beep(); return }
        store.edit("Reset \(wheel.title)") { state in
            state.updateClip(clipID) { clip in
                clip.color[keyPath: wheel.keyPath] = .neutral
                for property in wheel.allProperties { clip.animation.keyframes[property] = nil }
            }
        }
    }
}

/// Which RGB curve is being edited.
enum CurveChannel: String, CaseIterable, Identifiable {
    case master, red, green, blue

    var id: String { rawValue }
    var title: String { self == .master ? "Master" : rawValue.capitalized }
    var shortTitle: String { self == .master ? "RGB" : String(rawValue.prefix(1)).uppercased() }

    var keyPath: WritableKeyPath<RGBCurves, ToneCurve> {
        switch self {
        case .master: \.master
        case .red: \.red
        case .green: \.green
        case .blue: \.blue
        }
    }
}

extension EditorController {
    /// Replaces one RGB curve. During a drag (live edit) each call replaces the last.
    func setCurve(_ channel: CurveChannel, to curve: ToneCurve, of clipID: UUID, actionName: String = "Change Curve") {
        adjustClip(clipID, actionName: actionName) { $0.color.curves[keyPath: channel.keyPath] = curve }
    }

    func setHueCurve(_ curve: HueCurve, of clipID: UUID, actionName: String = "Change Hue vs Saturation") {
        adjustClip(clipID, actionName: actionName) { $0.color.hueSaturation = curve }
    }

    /// Asks for a .cube file and applies it to the clip.
    func chooseLUT(for clipID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Choose a LUT"
        panel.message = "Choose a 3D .cube LUT file."
        panel.prompt = "Use LUT"
        panel.allowedContentTypes = [.init(filenameExtension: "cube") ?? .data]
        if let current = state.clip(clipID)?.color.lut {
            panel.directoryURL = current.resolveURL().deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try setLUT(url, for: clipID)
        } catch {
            alert = EditorAlert(title: "Couldn’t use “\(url.lastPathComponent)”",
                                message: error.localizedDescription)
        }
    }

    /// Validates a .cube file and makes it the clip's LUT. Throws (changing nothing) if
    /// the file can't be read.
    func setLUT(_ url: URL, for clipID: UUID) throws {
        _ = try CubeLUT.load(from: url)
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let reference = LUTReference(name: url.deletingPathExtension().lastPathComponent, path: url.path, bookmark: bookmark)
        adjustClip(clipID, actionName: "Apply LUT") { $0.color.lut = reference }
    }

    func removeLUT(from clipID: UUID) {
        adjustClip(clipID, actionName: "Remove LUT") { clip in
            clip.color.lut = nil
            clip.color.lutIntensity = 1
            clip.animation.keyframes[.lutIntensity] = nil
        }
    }

    /// Whether a clip has a LUT whose file is missing or unreadable (it renders without it).
    func lutProblem(of clip: Clip) -> String? {
        guard let lut = clip.color.lut else { return nil }
        if case .failure(let error) = LUTLibrary.shared.result(for: lut) {
            return "LUT “\(lut.name)” can’t be used: \(error.localizedDescription) The clip shows without it."
        }
        return nil
    }
}
