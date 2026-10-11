import Foundation

/// How a value travels from one keyframe to the next.
/// The named easings are the standard CSS timing curves; `bezier` is any cubic
/// timing curve from (0,0) to (1,1) with control points (x1,y1) and (x2,y2).
nonisolated enum Easing: Codable, Hashable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case bezier(x1: Double, y1: Double, x2: Double, y2: Double)

    /// Control points of the equivalent cubic Bézier (nil for linear).
    var controlPoints: (x1: Double, y1: Double, x2: Double, y2: Double)? {
        switch self {
        case .linear: nil
        case .easeIn: (0.42, 0, 1, 1)
        case .easeOut: (0, 0, 0.58, 1)
        case .easeInOut: (0.42, 0, 0.58, 1)
        case let .bezier(x1, y1, x2, y2): (x1.clamped(to: 0...1), y1, x2.clamped(to: 0...1), y2)
        }
    }

    /// Eased progress for linear progress `u` in 0…1.
    func apply(_ u: Double) -> Double {
        let u = u.clamped(to: 0...1)
        guard let p = controlPoints else { return u }
        return Bezier(p).y(atX: u)
    }

    /// Splits the curve at linear progress `s` into the two curves that, applied to
    /// the sub-segments, reproduce the original exactly (used when blading).
    func split(at s: Double) -> (left: Easing, right: Easing) {
        guard let p = controlPoints, s > 0, s < 1 else { return (self, self) }
        let curve = Bezier(p)
        let t = curve.parameter(atX: s)
        let (left, right) = curve.subdivide(at: t)
        return (left.normalizedEasing(), right.normalizedEasing())
    }
}

/// A cubic Bézier from (0,0) to (1,1), as used for timing curves.
nonisolated private struct Bezier {
    var p0 = (x: 0.0, y: 0.0), p1: (x: Double, y: Double), p2: (x: Double, y: Double), p3 = (x: 1.0, y: 1.0)

    init(_ c: (x1: Double, y1: Double, x2: Double, y2: Double)) {
        p1 = (c.x1, c.y1)
        p2 = (c.x2, c.y2)
    }

    init(_ p0: (x: Double, y: Double), _ p1: (x: Double, y: Double), _ p2: (x: Double, y: Double), _ p3: (x: Double, y: Double)) {
        self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3
    }

    private func point(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        let m = 1 - t
        return m * m * m * a + 3 * m * m * t * b + 3 * m * t * t * c + t * t * t * d
    }

    func x(_ t: Double) -> Double { point(t, p0.x, p1.x, p2.x, p3.x) }
    func y(_ t: Double) -> Double { point(t, p0.y, p1.y, p2.y, p3.y) }

    /// The curve parameter whose x is `x` (x is monotonic for valid timing curves).
    func parameter(atX target: Double) -> Double {
        // Bisection to full double precision; x(t) is monotonic on [0, 1].
        var low = 0.0, high = 1.0
        for _ in 0..<64 {
            let mid = (low + high) / 2
            if x(mid) < target { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    func y(atX x: Double) -> Double { y(parameter(atX: x)) }

    /// De Casteljau subdivision at parameter t.
    func subdivide(at t: Double) -> (Bezier, Bezier) {
        func lerp(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> (x: Double, y: Double) {
            (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        }
        let p01 = lerp(p0, p1), p12 = lerp(p1, p2), p23 = lerp(p2, p3)
        let p012 = lerp(p01, p12), p123 = lerp(p12, p23)
        let mid = lerp(p012, p123)
        return (Bezier(p0, p01, p012, mid), Bezier(mid, p123, p23, p3))
    }

    /// Rescales this piece to the unit square and returns it as an easing. A piece
    /// whose ends have the same height carries no change, so linear is exact there.
    func normalizedEasing() -> Easing {
        let width = p3.x - p0.x, height = p3.y - p0.y
        guard abs(width) > 1e-12, abs(height) > 1e-12 else { return .linear }
        return .bezier(x1: (p1.x - p0.x) / width, y1: (p1.y - p0.y) / height,
                       x2: (p2.x - p0.x) / width, y2: (p2.y - p0.y) / height)
    }
}

nonisolated struct Keyframe: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    /// Time from the start of the clip.
    var time: Time
    var value: Double
    /// Easing of the segment that starts at this keyframe.
    var easing: Easing = .linear
}

/// A clip parameter that can be keyframed.
nonisolated enum AnimatableProperty: String, Codable, CaseIterable, Identifiable, Sendable, CodingKeyRepresentable {
    case positionX, positionY, scale, rotation, opacity, yaw, pitch
    // Color grade (Color tab).
    case exposure, brightness, contrast, saturation, temperature, tint, highlights, shadows
    case liftX, liftY, liftMaster, gammaX, gammaY, gammaMaster
    case gainX, gainY, gainMaster, offsetX, offsetY, offsetMaster
    case lutIntensity
    // Audio clips (Audio tab).
    case volume, pan
    // Speed Change (a speed ramp; video and audio).
    case speed

    var id: String { rawValue }

    /// Motion parameters belong to the Effects tab, grade parameters to the Color tab
    /// and sound parameters to the Audio tab.
    var isMotion: Bool { Self.motion.contains(self) }
    var isColor: Bool { Self.grade.contains(self) }
    var isAudio: Bool { Self.audio.contains(self) }
    /// Speed keyframes, edited by Speed (Edit tab) and Speed Change (Effects and Audio tabs).
    var isSpeed: Bool { self == .speed }
    static let motion: [AnimatableProperty] = [.positionX, .positionY, .scale, .rotation, .opacity, .yaw, .pitch]
    static let audio: [AnimatableProperty] = [.volume, .pan]
    static let grade: [AnimatableProperty] = allCases.filter { !motion.contains($0) && !audio.contains($0) && $0 != .speed }

    var title: String {
        switch self {
        case .positionX: "Position X"
        case .positionY: "Position Y"
        case .scale: "Zoom"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        case .yaw: "Yaw"
        case .pitch: "Pitch"
        case .exposure: "Exposure"
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .liftX: "Lift Color X"
        case .liftY: "Lift Color Y"
        case .liftMaster: "Lift"
        case .gammaX: "Gamma Color X"
        case .gammaY: "Gamma Color Y"
        case .gammaMaster: "Gamma"
        case .gainX: "Gain Color X"
        case .gainY: "Gain Color Y"
        case .gainMaster: "Gain"
        case .offsetX: "Offset Color X"
        case .offsetY: "Offset Color Y"
        case .offsetMaster: "Offset"
        case .lutIntensity: "LUT Intensity"
        case .volume: "Volume"
        case .pan: "Pan"
        case .speed: "Speed"
        }
    }

    var defaultValue: Double {
        switch self {
        case .scale, .opacity, .contrast, .saturation, .lutIntensity, .volume, .speed: 1
        default: 0
        }
    }

    /// Where the un-animated value is stored on the clip.
    var keyPath: WritableKeyPath<Clip, Double> {
        switch self {
        case .positionX: \.transform.positionX
        case .positionY: \.transform.positionY
        case .scale: \.transform.scale
        case .rotation: \.transform.rotation
        case .opacity: \.opacity
        case .yaw: \.transform.yaw
        case .pitch: \.transform.pitch
        case .exposure: \.color.exposure
        case .brightness: \.color.brightness
        case .contrast: \.color.contrast
        case .saturation: \.color.saturation
        case .temperature: \.color.temperature
        case .tint: \.color.tint
        case .highlights: \.color.highlights
        case .shadows: \.color.shadows
        case .liftX: \.color.lift.x
        case .liftY: \.color.lift.y
        case .liftMaster: \.color.lift.master
        case .gammaX: \.color.gamma.x
        case .gammaY: \.color.gamma.y
        case .gammaMaster: \.color.gamma.master
        case .gainX: \.color.gain.x
        case .gainY: \.color.gain.y
        case .gainMaster: \.color.gain.master
        case .offsetX: \.color.offset.x
        case .offsetY: \.color.offset.y
        case .offsetMaster: \.color.offset.master
        case .lutIntensity: \.color.lutIntensity
        case .volume: \.volume
        case .pan: \.pan
        case .speed: \.speed
        }
    }

    /// Valid values. Position limits depend on the project size and are applied by the UI.
    var range: ClosedRange<Double> {
        switch self {
        case .positionX, .positionY: -100_000...100_000
        case .scale: 0.1...4
        case .rotation: -3600...3600
        case .opacity: 0...1
        case .yaw, .pitch: -89...89
        case .exposure: -3...3
        case .contrast, .saturation: 0...2
        case .lutIntensity: 0...1
        // Linear gain: silence to +12 dB.
        case .volume: 0...AudioLevel.linear(fromDB: 12)
        case .speed: TimeRemap.range
        default: -1...1
        }
    }
}

/// Keyframes for each animated parameter. A parameter with no keyframes uses the
/// clip's plain value.
nonisolated struct ClipAnimation: Codable, Hashable, Sendable {
    var keyframes: [AnimatableProperty: [Keyframe]] = [:]

    var isEmpty: Bool { keyframes.values.allSatisfy(\.isEmpty) }

    func keyframes(for property: AnimatableProperty) -> [Keyframe] {
        keyframes[property] ?? []
    }

    /// Value of a parameter `offset` after the clip's start, or nil if it isn't animated.
    /// Before the first keyframe it holds the first value; after the last, the last.
    func value(of property: AnimatableProperty, atOffset offset: Time) -> Double? {
        let frames = keyframes(for: property)
        guard !frames.isEmpty else { return nil }
        return Self.interpolate(frames, atOffset: offset)
    }

    /// The value of sorted keyframes at an offset (shared with Labs parameters).
    static func interpolate(_ frames: [Keyframe], atOffset offset: Time) -> Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if offset <= first.time { return first.value }
        if offset >= last.time { return last.value }
        for (a, b) in zip(frames, frames.dropFirst()) where offset >= a.time && offset <= b.time {
            let span = Double((b.time - a.time).ticks)
            let u = span > 0 ? Double((offset - a.time).ticks) / span : 1
            return a.value + (b.value - a.value) * a.easing.apply(u)
        }
        return last.value
    }

    /// Adds or replaces the keyframe at `time` (keeping its easing if it existed).
    mutating func setKeyframe(_ property: AnimatableProperty, at time: Time, value: Double) {
        var frames = keyframes(for: property)
        if let index = frames.firstIndex(where: { $0.time == time }) {
            frames[index].value = value
        } else {
            frames.append(Keyframe(time: time, value: value))
        }
        keyframes[property] = frames.sorted { $0.time < $1.time }
    }

    mutating func removeKeyframe(_ property: AnimatableProperty, id: UUID) {
        var frames = keyframes(for: property)
        frames.removeAll { $0.id == id }
        keyframes[property] = frames.isEmpty ? nil : frames
    }

    /// Splits the animation at `offset` for blading: the left part ends exactly at the
    /// value at the cut and the right part (re-timed to start at zero) begins there,
    /// with easing curves subdivided so both halves follow the original motion.
    func split(at offset: Time) -> (left: ClipAnimation, right: ClipAnimation) {
        var left = ClipAnimation(), right = ClipAnimation()
        for (property, frames) in keyframes where !frames.isEmpty {
            let (l, r) = Self.split(frames, at: offset)
            left.keyframes[property] = l
            right.keyframes[property] = r
        }
        return (left, right)
    }

    /// Splits sorted keyframes at `offset` (shared with Labs parameters): the left part
    /// ends at the value at the cut, the right part starts there re-timed to zero, and
    /// the crossing segment's easing is subdivided so neither half changes shape.
    static func split(_ frames: [Keyframe], at offset: Time) -> (left: [Keyframe], right: [Keyframe]) {
        let valueAtCut = interpolate(frames, atOffset: offset)
        func shiftedToCut(_ frame: Keyframe) -> Keyframe {
            var f = frame
            f.time = frame.time - offset
            return f
        }
        var leftFrames: [Keyframe]
        var rightFrames: [Keyframe]
        if frames.contains(where: { $0.time == offset }) {
            // The cut is on a keyframe: nothing to subdivide, both halves keep it.
            leftFrames = frames.filter { $0.time <= offset }
            rightFrames = frames.filter { $0.time >= offset }.map(shiftedToCut)
        } else {
            leftFrames = frames.filter { $0.time < offset }
            rightFrames = frames.filter { $0.time > offset }.map(shiftedToCut)
            var rightEasing = Easing.linear
            // Subdivide the segment that crosses the cut.
            if let a = leftFrames.last, let b = rightFrames.first {
                let bTime = b.time + offset
                let span = Double((bTime - a.time).ticks)
                let s = span > 0 ? Double((offset - a.time).ticks) / span : 0
                let (l, r) = a.easing.split(at: s)
                leftFrames[leftFrames.count - 1].easing = l
                rightEasing = r
            }
            leftFrames.append(Keyframe(time: offset, value: valueAtCut))
            rightFrames.insert(Keyframe(time: .zero, value: valueAtCut, easing: rightEasing), at: 0)
        }
        return (leftFrames, rightFrames)
    }

    /// Adds or replaces the keyframe at `time` in a sorted list (keeping its easing).
    static func setting(_ frames: [Keyframe], at time: Time, value: Double) -> [Keyframe] {
        var frames = frames
        if let index = frames.firstIndex(where: { $0.time == time }) {
            frames[index].value = value
        } else {
            frames.append(Keyframe(time: time, value: value))
        }
        return frames.sorted { $0.time < $1.time }
    }

    /// Moves every keyframe by `delta` (used when the clip's start is trimmed, so the
    /// animation stays put on the timeline).
    func shifted(by delta: Time) -> ClipAnimation {
        var result = self
        for (property, frames) in keyframes {
            result.keyframes[property] = frames.map { var f = $0; f.time = f.time + delta; return f }
        }
        return result
    }
}

/// All animatable values of a clip at one moment.
nonisolated struct ClipParameters: Equatable, Sendable {
    var positionX: Double
    var positionY: Double
    var scale: Double
    var rotation: Double
    var opacity: Double
    var yaw: Double
    var pitch: Double
}

nonisolated extension Clip {
    /// The single place animated values are computed. Preview, scrubbing and export
    /// all go through this, so they always agree.
    func value(of property: AnimatableProperty, at timelineTime: Time) -> Double {
        animation.value(of: property, atOffset: timelineTime - start) ?? self[keyPath: property.keyPath]
    }

    func parameters(at timelineTime: Time) -> ClipParameters {
        ClipParameters(
            positionX: value(of: .positionX, at: timelineTime),
            positionY: value(of: .positionY, at: timelineTime),
            scale: value(of: .scale, at: timelineTime),
            rotation: value(of: .rotation, at: timelineTime),
            opacity: value(of: .opacity, at: timelineTime),
            yaw: value(of: .yaw, at: timelineTime),
            pitch: value(of: .pitch, at: timelineTime)
        )
    }

    /// The grade at a moment, with keyframed color values evaluated there.
    func grade(at timelineTime: Time) -> ColorGrade {
        guard animation.keyframes.keys.contains(where: \.isColor) else { return color }
        var clip = self
        for property in AnimatableProperty.grade where isAnimated(property) {
            clip[keyPath: property.keyPath] = value(of: property, at: timelineTime)
        }
        return clip.color
    }

    func isAnimated(_ property: AnimatableProperty) -> Bool {
        !animation.keyframes(for: property).isEmpty
    }
}
