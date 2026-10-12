import CoreMedia

/// Exact timeline time stored as integer ticks at 600 ticks per second.
/// 600 is divisible by 24, 25, 30 and 60, so every project frame boundary is
/// represented exactly and repeated edits never accumulate floating-point drift.
nonisolated struct Time: Codable, Hashable, Comparable, Sendable {
    static let ticksPerSecond: Int64 = 600

    var ticks: Int64

    init(ticks: Int64) { self.ticks = ticks }

    init(seconds: Double) {
        ticks = Int64((seconds * Double(Self.ticksPerSecond)).rounded())
    }

    init(_ time: CMTime) {
        guard time.isNumeric else { self.ticks = 0; return }
        ticks = time.convertScale(Int32(Self.ticksPerSecond), method: .roundHalfAwayFromZero).value
    }

    static let zero = Time(ticks: 0)

    var seconds: Double { Double(ticks) / Double(Self.ticksPerSecond) }
    var cmTime: CMTime { CMTime(value: ticks, timescale: CMTimeScale(Self.ticksPerSecond)) }

    static func frame(fps: Int) -> Time { Time(ticks: ticksPerSecond / Int64(fps)) }

    /// Rounds up to the next frame boundary of the given frame rate (unchanged if on one).
    func roundedUpToFrame(fps: Int) -> Time {
        let frame = Self.ticksPerSecond / Int64(max(fps, 1))
        guard frame > 0 else { return self }
        return Time(ticks: (ticks + frame - 1) / frame * frame)
    }

    /// Rounds to the nearest frame boundary of the given frame rate.
    func snappedToFrame(fps: Int) -> Time {
        let frame = Self.ticksPerSecond / Int64(fps)
        let rounded = (Double(ticks) / Double(frame)).rounded() * Double(frame)
        return Time(ticks: Int64(rounded))
    }

    func scaled(by factor: Double) -> Time {
        Time(ticks: Int64((Double(ticks) * factor).rounded()))
    }

    func clamped(_ lower: Time, _ upper: Time) -> Time { max(lower, min(upper, self)) }

    static func < (lhs: Time, rhs: Time) -> Bool { lhs.ticks < rhs.ticks }
    static func + (lhs: Time, rhs: Time) -> Time { Time(ticks: lhs.ticks + rhs.ticks) }
    static func - (lhs: Time, rhs: Time) -> Time { Time(ticks: lhs.ticks - rhs.ticks) }
    static func += (lhs: inout Time, rhs: Time) { lhs.ticks += rhs.ticks }
    static func -= (lhs: inout Time, rhs: Time) { lhs.ticks -= rhs.ticks }
    static prefix func - (value: Time) -> Time { Time(ticks: -value.ticks) }

    // Codable as a bare integer keeps project files compact and readable.
    init(from decoder: Decoder) throws {
        ticks = try decoder.singleValueContainer().decode(Int64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ticks)
    }
}

/// A half-open range [start, end) on the timeline.
nonisolated struct TimeRange: Hashable, Sendable {
    var start: Time
    var end: Time

    var duration: Time { end - start }

    func contains(_ time: Time) -> Bool { time >= start && time < end }
    func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }

    var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, end: end.cmTime) }
}

nonisolated enum Timecode {
    /// Formats as HH:MM:SS:FF (hours omitted when zero).
    static func string(for time: Time, fps: Int, alwaysShowHours: Bool = false) -> String {
        let fps64 = Int64(max(fps, 1))
        let totalFrames = (time.ticks * fps64) / Time.ticksPerSecond
        let frames = totalFrames % fps64
        let totalSeconds = totalFrames / fps64
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        if hours > 0 || alwaysShowHours {
            return String(format: "%02lld:%02lld:%02lld:%02lld", hours, minutes, seconds, frames)
        }
        return String(format: "%02lld:%02lld:%02lld", minutes, seconds, frames)
    }

    /// Parses "HH:MM:SS:FF", "MM:SS:FF", "SS:FF" or plain seconds ("2.5").
    static func parse(_ text: String, fps: Int) -> Time? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if !trimmed.contains(":") {
            guard let seconds = Double(trimmed), seconds >= 0 else { return nil }
            return Time(seconds: seconds)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count >= 2, parts.count <= 4, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let values = Array(repeating: 0, count: 4 - parts.count) + parts.map { $0! }
        let (h, m, s, f) = (values[0], values[1], values[2], values[3])
        guard f < max(fps, 1) else { return nil }
        let seconds = Double(h * 3600 + m * 60 + s) + Double(f) / Double(max(fps, 1))
        return Time(seconds: seconds)
    }

    /// Short label for ruler ticks: "1:05", "0:10", or "0:10:12" for frame-level ticks.
    static func rulerLabel(for time: Time, fps: Int, showFrames: Bool) -> String {
        let totalSeconds = time.ticks / Time.ticksPerSecond
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if showFrames {
            let frames = ((time.ticks % Time.ticksPerSecond) * Int64(fps)) / Time.ticksPerSecond
            return String(format: "%lld:%02lld:%02lld", minutes, seconds, frames)
        }
        if minutes >= 60 {
            return String(format: "%lld:%02lld:%02lld", minutes / 60, minutes % 60, seconds)
        }
        return String(format: "%lld:%02lld", minutes, seconds)
    }
}
