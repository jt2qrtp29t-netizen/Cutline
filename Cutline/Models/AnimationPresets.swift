import Foundation

/// Ready-made animations. Applying one writes ordinary keyframes onto the clip, so
/// the result stays editable in the keyframe lane and curve editor.
///
/// Presets are relative to what the clip already does: a slide offsets the clip's
/// current position, a fade scales its current opacity. That way a preset combines
/// with existing keyframes instead of resetting them.
nonisolated enum AnimationPreset: String, CaseIterable, Identifiable, Sendable {
    case fade, slideLeft, slideRight, slideUp, slideDown, zoomPop, bounce, shake
    /// Gameplay presets, applied at the playhead.
    case zoomPunch, screenShake

    var id: String { rawValue }

    static let inOutPresets: [AnimationPreset] = [.fade, .slideLeft, .slideRight, .slideUp, .slideDown, .zoomPop, .bounce, .shake]
    static let gameplayPresets: [AnimationPreset] = [.zoomPunch, .screenShake]

    var isGameplay: Bool { self == .zoomPunch || self == .screenShake }

    /// Where a preset goes on the clip.
    enum Placement: Sendable, Equatable {
        /// Plays from the clip's first frame.
        case animateIn
        /// Plays into the clip's last frame.
        case animateOut
        /// Starts at this offset into the clip (gameplay presets).
        case at(Time)
    }

    func title(for placement: Placement) -> String {
        let isIn = placement == .animateIn
        switch self {
        case .fade: return isIn ? "Fade In" : "Fade Out"
        case .slideLeft: return isIn ? "Slide In from Left" : "Slide Out to Left"
        case .slideRight: return isIn ? "Slide In from Right" : "Slide Out to Right"
        case .slideUp: return isIn ? "Slide In from Top" : "Slide Out to Top"
        case .slideDown: return isIn ? "Slide In from Bottom" : "Slide Out to Bottom"
        case .zoomPop: return isIn ? "Zoom Pop In" : "Zoom Pop Out"
        case .bounce: return isIn ? "Bounce In" : "Bounce Out"
        case .shake: return isIn ? "Shake In" : "Shake Out"
        case .zoomPunch: return "Zoom Punch"
        case .screenShake: return "Screen Shake"
        }
    }

    var shortTitle: String {
        switch self {
        case .fade: "Fade"
        case .slideLeft: "Left"
        case .slideRight: "Right"
        case .slideUp: "Top"
        case .slideDown: "Bottom"
        case .zoomPop: "Zoom Pop"
        case .bounce: "Bounce"
        case .shake: "Shake"
        case .zoomPunch: "Zoom Punch"
        case .screenShake: "Screen Shake"
        }
    }

    var symbolName: String {
        switch self {
        case .fade: "circle.lefthalf.filled"
        case .slideLeft: "arrow.right.to.line"
        case .slideRight: "arrow.left.to.line"
        case .slideUp: "arrow.down.to.line"
        case .slideDown: "arrow.up.to.line"
        case .zoomPop: "plus.magnifyingglass"
        case .bounce: "arrow.up.and.down"
        case .shake: "water.waves"
        case .zoomPunch: "scope"
        case .screenShake: "waveform.path"
        }
    }

    /// Default length of each preset.
    var defaultDuration: Double {
        switch self {
        case .zoomPunch: 0.45
        case .screenShake: 0.5
        case .bounce: 0.9
        default: 0.5
        }
    }

    // MARK: Shapes

    /// How a step changes the parameter's own value at that time.
    private enum Change {
        /// Added to the value (position, rotation).
        case add(Double)
        /// Multiplies the value (zoom, opacity).
        case multiply(Double)
    }

    /// One keyframe of a preset: a fraction of the preset's length, the change, and
    /// the easing towards the next step.
    private struct Step {
        var at: Double
        var change: Change
        var easing: Easing = .linear
    }

    /// The steps of the "in" version, per parameter. "Out" plays them backwards in time.
    private func steps(settings: ProjectSettings) -> [AnimatableProperty: [Step]] {
        let width = Double(settings.width), height = Double(settings.height)
        switch self {
        case .fade:
            return [.opacity: [Step(at: 0, change: .multiply(0), easing: .easeOut), Step(at: 1, change: .multiply(1))]]
        case .slideLeft:
            return [.positionX: [Step(at: 0, change: .add(-width), easing: .easeOut), Step(at: 1, change: .add(0))]]
        case .slideRight:
            return [.positionX: [Step(at: 0, change: .add(width), easing: .easeOut), Step(at: 1, change: .add(0))]]
        case .slideUp:
            return [.positionY: [Step(at: 0, change: .add(-height), easing: .easeOut), Step(at: 1, change: .add(0))]]
        case .slideDown:
            return [.positionY: [Step(at: 0, change: .add(height), easing: .easeOut), Step(at: 1, change: .add(0))]]
        case .zoomPop:
            return [
                .scale: [Step(at: 0, change: .multiply(0), easing: .easeOut),
                         Step(at: 0.7, change: .multiply(1.12), easing: .easeInOut),
                         Step(at: 1, change: .multiply(1))],
                .opacity: [Step(at: 0, change: .multiply(0), easing: .easeOut), Step(at: 0.35, change: .multiply(1))],
            ]
        case .bounce:
            // Drops in from above and settles with two smaller bounces.
            let drop = height * 0.6
            return [.positionY: [
                Step(at: 0, change: .add(-drop), easing: .easeIn),
                Step(at: 0.45, change: .add(0), easing: .easeOut),
                Step(at: 0.65, change: .add(-drop * 0.2), easing: .easeIn),
                Step(at: 0.82, change: .add(0), easing: .easeOut),
                Step(at: 0.92, change: .add(-drop * 0.05), easing: .easeIn),
                Step(at: 1, change: .add(0)),
            ]]
        case .shake:
            // Side-to-side wobble that dies down.
            let amplitude = width * 0.025
            let swings = 8
            let steps = (0...swings).map { i -> Step in
                let decay = 1 - Double(i) / Double(swings)
                let sign: Double = i.isMultiple(of: 2) ? 1 : -1
                return Step(at: Double(i) / Double(swings), change: .add(i == swings ? 0 : sign * amplitude * decay), easing: .easeInOut)
            }
            return [.positionX: steps]
        case .zoomPunch:
            // A fast push in, then an eased settle back.
            return [.scale: [Step(at: 0, change: .multiply(1), easing: .easeOut),
                             Step(at: 0.18, change: .multiply(1.25), easing: .easeInOut),
                             Step(at: 1, change: .multiply(1))]]
        case .screenShake:
            // Jittery camera shake on both axes that dies down. Fixed pseudo-random
            // offsets, so applying it twice gives the same result.
            let amplitude = width * 0.018
            let count = 12
            var x: [Step] = [Step(at: 0, change: .add(0))]
            var y: [Step] = [Step(at: 0, change: .add(0))]
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func random() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(seed >> 11) / Double(1 << 53) * 2 - 1
            }
            for i in 1..<count {
                let decay = 1 - Double(i) / Double(count)
                let at = Double(i) / Double(count)
                x.append(Step(at: at, change: .add(random() * amplitude * decay)))
                y.append(Step(at: at, change: .add(random() * amplitude * decay)))
            }
            x.append(Step(at: 1, change: .add(0)))
            y.append(Step(at: 1, change: .add(0)))
            return [.positionX: x, .positionY: y]
        }
    }

    // MARK: Applying

    /// The clip with this preset's keyframes written in. Keyframes the preset covers
    /// are replaced; everything else stays.
    func apply(to clip: Clip, placement: Placement, duration: Double, settings: ProjectSettings) -> Clip {
        let frame = Time.frame(fps: settings.frameRate)
        // The last frame shown is one frame before the clip's end.
        let lastFrame = max(clip.duration - frame, .zero)
        let length = Time(seconds: duration).clamped(frame, max(lastFrame, frame))

        let window: (start: Time, end: Time)
        switch placement {
        case .animateIn:
            window = (.zero, min(length, lastFrame))
        case .animateOut:
            window = (max(lastFrame - length, .zero), lastFrame)
        case .at(let offset):
            let start = offset.clamped(.zero, lastFrame)
            window = (start, min(start + length, lastFrame))
        }
        let span = window.end - window.start
        guard span > .zero else { return clip }

        var result = clip
        for (property, steps) in steps(settings: settings) {
            // "Out" runs the shape backwards; each step's easing then belongs to the
            // segment that now ends there, so shift easings by one and mirror them.
            let ordered: [Step]
            if placement == .animateOut {
                let reversed = Array(steps.reversed())
                ordered = reversed.enumerated().map { index, step in
                    var s = step
                    s.at = 1 - step.at
                    s.easing = index + 1 < reversed.count ? reversed[index + 1].easing.mirrored : .linear
                    return s
                }
            } else {
                ordered = steps
            }

            var frames = clip.animation.keyframes(for: property).filter { $0.time < window.start || $0.time > window.end }
            for step in ordered {
                let time = (window.start + span.scaled(by: step.at)).snappedToFrame(fps: settings.frameRate)
                let base = clip.value(of: property, at: clip.start + time)
                let value: Double = switch step.change {
                case .add(let amount): base + amount
                case .multiply(let factor): base * factor
                }
                frames.removeAll { $0.time == time }
                frames.append(Keyframe(time: time, value: value.clamped(to: property.range), easing: step.easing))
            }
            result.animation.keyframes[property] = frames.sorted { $0.time < $1.time }
        }
        return result
    }
}

nonisolated extension Easing {
    /// The same curve played backwards in time (ease in ↔ ease out).
    var mirrored: Easing {
        switch self {
        case .linear: .linear
        case .easeIn: .easeOut
        case .easeOut: .easeIn
        case .easeInOut: .easeInOut
        case let .bezier(x1, y1, x2, y2): .bezier(x1: 1 - x2, y1: 1 - y2, x2: 1 - x1, y2: 1 - y1)
        }
    }
}
