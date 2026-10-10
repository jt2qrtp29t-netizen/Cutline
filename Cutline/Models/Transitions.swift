import Foundation

nonisolated enum TransitionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case crossDissolve, dipToBlack, slideLeft, slideRight, slideUp, slideDown, zoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crossDissolve: "Cross Dissolve"
        case .dipToBlack: "Dip to Black"
        case .slideLeft: "Slide Left"
        case .slideRight: "Slide Right"
        case .slideUp: "Slide Up"
        case .slideDown: "Slide Down"
        case .zoom: "Zoom"
        }
    }

    var symbolName: String {
        switch self {
        case .crossDissolve: "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .dipToBlack: "circle.bottomhalf.filled"
        case .slideLeft: "arrow.left.square"
        case .slideRight: "arrow.right.square"
        case .slideUp: "arrow.up.square"
        case .slideDown: "arrow.down.square"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// A transition on the cut between two touching clips on the same track. It's
/// centered on the cut: the outgoing clip continues past its end for half the
/// duration while the incoming clip starts half the duration early, using the
/// media beyond each edit point (or holding the edge frame if there isn't any).
nonisolated struct Transition: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var kind: TransitionKind
    var duration: Time
    /// The clip ending at the cut and the clip starting there.
    var outgoingClipID: UUID
    var incomingClipID: UUID

    static let defaultDuration = Time(seconds: 1)
    static let minimumDuration = Time.frame(fps: 60)
}

/// Where a transition actually plays, after limiting it to what its clips allow.
nonisolated struct PlacedTransition: Hashable, Sendable {
    let transition: Transition
    let outgoing: Clip
    let incoming: Clip
    /// The cut, and the effective (possibly shortened) duration.
    let cut: Time
    let duration: Time

    var range: TimeRange {
        let half = Time(ticks: duration.ticks / 2)
        return TimeRange(start: cut - half, end: cut - half + duration)
    }

    /// 0 at the start of the transition, 1 at its end.
    func progress(at time: Time) -> Double {
        let r = range
        guard r.duration > .zero else { return 1 }
        return (Double((time - r.start).ticks) / Double(r.duration.ticks)).clamped(to: 0...1)
    }
}

nonisolated extension Track {
    /// This track's transitions whose clips still touch, with durations limited so
    /// that a transition is never longer than either clip and the two transitions
    /// at a clip's ends never overlap.
    func placedTransitions() -> [PlacedTransition] {
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var result: [PlacedTransition] = []
        for transition in transitions {
            guard let outgoing = byID[transition.outgoingClipID], let incoming = byID[transition.incomingClipID],
                  outgoing.end == incoming.start else { continue }
            var duration = min(transition.duration, outgoing.duration, incoming.duration)
            // Share each clip between the transitions at its two ends.
            let outgoingOther = transitions.first { $0.incomingClipID == outgoing.id }?.duration ?? .zero
            let incomingOther = transitions.first { $0.outgoingClipID == incoming.id }?.duration ?? .zero
            if Time(ticks: duration.ticks / 2) + Time(ticks: outgoingOther.ticks / 2) > outgoing.duration
                || Time(ticks: duration.ticks / 2) + Time(ticks: incomingOther.ticks / 2) > incoming.duration {
                duration = min(outgoing.duration, incoming.duration)
                    .scaled(by: 0.5)
            }
            duration = max(duration, Transition.minimumDuration)
            result.append(PlacedTransition(transition: transition, outgoing: outgoing, incoming: incoming,
                                           cut: incoming.start, duration: duration))
        }
        return result.sorted { $0.cut < $1.cut }
    }

    /// How far a clip's media has to extend past its start and end to cover its transitions.
    func transitionHandles(for clipID: UUID) -> (lead: Time, tail: Time) {
        var lead = Time.zero, tail = Time.zero
        for placed in placedTransitions() {
            let half = placed.cut - placed.range.start
            let rest = placed.range.end - placed.cut
            if placed.incoming.id == clipID { lead = half }
            if placed.outgoing.id == clipID { tail = rest }
        }
        return (lead, tail)
    }
}

nonisolated extension ProjectState {
    /// Drops transitions whose clips no longer touch (moved, trimmed or deleted).
    mutating func pruneTransitions() {
        for index in tracks.indices where !tracks[index].transitions.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: tracks[index].clips.map { ($0.id, $0) })
            tracks[index].transitions.removeAll { t in
                guard let a = byID[t.outgoingClipID], let b = byID[t.incomingClipID] else { return true }
                return a.end != b.start
            }
        }
    }

    /// Adds (or replaces) the transition on the cut between two touching clips.
    @discardableResult
    mutating func addTransition(_ kind: TransitionKind, between outgoingID: UUID, and incomingID: UUID,
                                duration: Time = Transition.defaultDuration) -> UUID? {
        guard let t = trackIndex(ofClip: outgoingID), trackIndex(ofClip: incomingID) == t,
              tracks[t].kind.isVisual,
              let a = clip(outgoingID), let b = clip(incomingID), a.end == b.start
        else { return nil }
        tracks[t].transitions.removeAll { $0.outgoingClipID == outgoingID && $0.incomingClipID == incomingID }
        let transition = Transition(kind: kind, duration: duration, outgoingClipID: outgoingID, incomingClipID: incomingID)
        tracks[t].transitions.append(transition)
        return transition.id
    }

    /// The touching clip pair whose cut is nearest `time` on a track, within `tolerance`.
    func cut(onTrack index: Int, near time: Time, tolerance: Time) -> (outgoing: Clip, incoming: Clip)? {
        guard tracks.indices.contains(index) else { return nil }
        let clips = tracks[index].clips.sorted { $0.start < $1.start }
        let pairs = zip(clips, clips.dropFirst()).filter { $0.end == $1.start }
        guard let best = pairs.min(by: { abs(($0.1.start - time).ticks) < abs(($1.1.start - time).ticks) }),
              abs((best.1.start - time).ticks) <= tolerance.ticks else { return nil }
        return (best.0, best.1)
    }

    func transition(_ id: UUID) -> (trackIndex: Int, transition: Transition)? {
        for (index, track) in tracks.enumerated() {
            if let found = track.transitions.first(where: { $0.id == id }) { return (index, found) }
        }
        return nil
    }
}
