import Foundation

/// How slowed-down (or sped-up) video shows frames between source frames.
nonisolated enum RetimeQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The source frame at that moment (frames repeat in slow motion).
    case nearest
    /// The two neighboring source frames mixed by how far between them the moment is.
    case frameBlend

    var id: String { rawValue }
    var title: String { self == .nearest ? "Nearest" : "Frame Blend" }
}

/// The one time-remap function for a clip: how far into the source (from the clip's
/// in-point) a timeline offset (from the clip's start) has reached. Source time is the
/// integral of speed, so a ramp from 100% to 50% plays the source progressively slower.
/// With no speed keyframes it's the clip's constant speed, exactly as before.
/// Shared by the video composition, the audio engine, scrubbing, thumbnails and editing.
nonisolated struct TimeRemap: Sendable, Equatable {
    /// The constant speed (when there are no keyframes).
    let speed: Double
    /// Speed keyframes at offsets from the clip's start.
    let frames: [Keyframe]

    static let range = 0.1...10.0

    init(speed: Double, frames: [Keyframe]) {
        self.speed = speed
        self.frames = frames.sorted { $0.time < $1.time }
    }

    init(_ clip: Clip) {
        self.init(speed: clip.speed, frames: clip.animation.keyframes(for: .speed))
    }

    var isRamp: Bool { !frames.isEmpty }

    /// Speed at an offset (seconds from the clip's start).
    func speed(at offset: Double) -> Double {
        guard isRamp else { return speed }
        return ClipAnimation.interpolate(frames, atOffset: Time(seconds: offset)).clamped(to: Self.range)
    }

    /// Source seconds covered from the clip's start to `offset` (timeline seconds): ∫ speed.
    func sourceSeconds(at offset: Double) -> Double {
        guard isRamp, let first = frames.first, let last = frames.last else { return offset * speed }
        let t0 = first.time.seconds, tN = last.time.seconds
        let v0 = first.value.clamped(to: Self.range), vN = last.value.clamped(to: Self.range)
        // Before the first keyframe: its value. (Negative offsets extrapolate the same way.)
        if offset <= t0 { return offset * v0 }
        var total = t0 * v0
        for (a, b) in zip(frames, frames.dropFirst()) {
            let ta = a.time.seconds, tb = b.time.seconds
            guard tb > ta else { continue }
            let end = min(offset, tb)
            total += Self.segmentIntegral(from: a.value.clamped(to: Self.range), to: b.value.clamped(to: Self.range),
                                          easing: a.easing, span: tb - ta, upTo: end - ta)
            if offset <= tb { return total }
        }
        return total + (offset - tN) * vN
    }

    /// ∫ of va + (vb − va)·E(t / span) over [0, x].
    static func segmentIntegral(from va: Double, to vb: Double, easing: Easing, span: Double, upTo x: Double) -> Double {
        let u = (x / span).clamped(to: 0...1)
        let eased: Double
        if easing == .linear {
            eased = u * u / 2
        } else {
            // Simpson's rule on the easing curve (smooth, so 32 steps are exact to ~1e-9).
            let n = 32
            let h = u / Double(n)
            var sum = easing.apply(0) + easing.apply(u)
            for i in 1..<n { sum += easing.apply(Double(i) * h) * (i % 2 == 1 ? 4 : 2) }
            eased = sum * h / 3
        }
        return va * x + (vb - va) * span * eased
    }

    /// The timeline offset at which `source` seconds of source have played (the inverse).
    func offset(forSourceSeconds source: Double) -> Double {
        guard isRamp else { return source / speed }
        var low = 0.0, high = max(1, source / Self.range.lowerBound)
        while sourceSeconds(at: high) < source { high *= 2 }
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if sourceSeconds(at: mid) < source { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// Lowest and highest speed over [0, length].
    func extremes(over length: Double) -> ClosedRange<Double> {
        guard isRamp else { return speed...speed }
        var values = frames.filter { $0.time.seconds <= length }.map { $0.value.clamped(to: Self.range) }
        values.append(speed(at: 0))
        values.append(speed(at: length))
        // Eased segments stay between their ends, so the keyframes bound the curve.
        return (values.min() ?? speed)...(values.max() ?? speed)
    }
}

nonisolated extension Clip {
    var remap: TimeRemap { TimeRemap(self) }

    /// The clip's speed changes over time (it has speed keyframes).
    var hasSpeedRamp: Bool { !animation.keyframes(for: .speed).isEmpty }

    /// A short label for the clip's speed ("150%", or "50→200%" for a ramp); nil at 100%.
    var speedLabel: String? {
        let frames = animation.keyframes(for: .speed)
        if let first = frames.first, let last = frames.last {
            return String(format: "%.0f→%.0f%%", first.value * 100, last.value * 100)
        }
        return speed != 1 ? String(format: "%.0f%%", speed * 100) : nil
    }

    /// Played at anything other than constant 100%.
    var isRetimed: Bool { hasSpeedRamp || speed != 1 }

    /// The source span the clip plays, from its in-point.
    var sourceDuration: Time {
        hasSpeedRamp ? Time(seconds: remap.sourceSeconds(at: duration.seconds)) : duration.scaled(by: speed)
    }

    var sourceEnd: Time { sourceStart + sourceDuration }

    /// Source media time shown at a given timeline time.
    func sourceTime(at timelineTime: Time) -> Time {
        guard hasSpeedRamp else { return sourceStart + (timelineTime - start).scaled(by: speed) }
        return sourceStart + Time(seconds: remap.sourceSeconds(at: (timelineTime - start).seconds))
    }

    /// Speed at a timeline time.
    func speed(at timelineTime: Time) -> Double {
        remap.speed(at: (timelineTime - start).seconds)
    }

    /// Makes the clip as long as its speed curve needs to play `source` of source media:
    /// the keyframes keep their places relative to the clip (stretched or squeezed with it).
    mutating func refitDuration(toSource source: Time) {
        guard hasSpeedRamp else {
            duration = max(source.scaled(by: 1 / max(speed, 0.0001)), Time(ticks: TimelineEditing.minimumClipTicks))
            return
        }
        let old = max(duration.seconds, 1e-9)
        let frames = animation.keyframes(for: .speed)
        // The curve over a 1-second clip: its integral is the mean speed.
        let unit = TimeRemap(speed: speed, frames: frames.map { var f = $0; f.time = Time(seconds: $0.time.seconds / old); return f })
        let mean = max(unit.sourceSeconds(at: 1), 1e-9)
        let new = max(source.seconds / mean, Time(ticks: TimelineEditing.minimumClipTicks).seconds)
        animation.keyframes[.speed] = frames.map { var f = $0; f.time = Time(seconds: $0.time.seconds / old * new); return f }
        duration = Time(seconds: new)
    }
}

nonisolated extension ProjectState {
    /// After an edit, brings clips whose speed curve changed in line with it: the clip
    /// keeps the source it plays and gets the length its curve needs (following clips on
    /// its track ripple by the difference), and linked clips get the same curve.
    /// Constant-speed changes without keyframes are left exactly as they were made.
    mutating func refitSpeedChanges(from previous: ProjectState) {
        var done = Set<UUID>()
        for t in tracks.indices {
            for clip in tracks[t].clips where !done.contains(clip.id) {
                guard let before = previous.clip(clip.id), before.start == clip.start, before.duration == clip.duration,
                      before.sourceStart == clip.sourceStart, before.hasSpeedRamp || clip.hasSpeedRamp,
                      before.speed != clip.speed || before.animation.keyframes(for: .speed) != clip.animation.keyframes(for: .speed)
                else { continue }
                // The clip and everything linked to it share the new curve.
                let curve = clip.animation.keyframes(for: .speed)
                let progress = curve.map { ($0, $0.time.seconds / max(clip.duration.seconds, 1e-9)) }
                for id in linkedGroup(of: clip.id) where !done.contains(id) {
                    done.insert(id)
                    guard let old = previous.clip(id), let index = trackIndex(ofClip: id) else { continue }
                    updateClip(id) { c in
                        c.speed = clip.speed
                        c.animation.keyframes[.speed] = curve.isEmpty ? nil : progress.map { frame, p in
                            var f = frame
                            f.time = Time(seconds: p * c.duration.seconds)
                            return f
                        }
                        c.refitDuration(toSource: old.sourceDuration)
                    }
                    guard let refitted = self.clip(id) else { continue }
                    let delta = refitted.duration - old.duration
                    if delta != .zero {
                        for k in tracks[index].clips.indices where tracks[index].clips[k].id != id && tracks[index].clips[k].start >= old.end {
                            tracks[index].clips[k].start = tracks[index].clips[k].start + delta
                        }
                    }
                }
            }
        }
    }
}
