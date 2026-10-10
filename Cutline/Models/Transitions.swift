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

/// A transition on the cut between two touching clips on the same track, or on
/// a clip's open start or end (nothing touches it there), where it transitions
/// from or to nothing: black on V1, the tracks below on higher tracks.
///
/// On a cut it's centered: the outgoing clip continues past its end for half the
/// duration while the incoming clip starts half the duration early, using the
/// media beyond each edit point (or holding the edge frame if there isn't any).
/// On an open edge it plays within the clip.
nonisolated struct Transition: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var kind: TransitionKind
    var duration: Time
    /// The clip ending at the transition and the clip starting there. One of them
    /// is nil for a transition on an open edge.
    var outgoingClipID: UUID?
    var incomingClipID: UUID?

    static let defaultDuration = Time(seconds: 1.25)
    static let minimumDuration = Time.frame(fps: 60)
}

/// Where a transition actually plays, after limiting it to what its clips allow.
nonisolated struct PlacedTransition: Hashable, Sendable {
    let transition: Transition
    /// One of these is nil on an open edge.
    let outgoing: Clip?
    let incoming: Clip?
    /// The cut or edge, and the effective (possibly shortened) duration.
    let cut: Time
    let duration: Time

    var isEdge: Bool { outgoing == nil || incoming == nil }

    var range: TimeRange {
        if outgoing == nil { return TimeRange(start: cut, end: cut + duration) }
        if incoming == nil { return TimeRange(start: cut - duration, end: cut) }
        let half = Time(ticks: duration.ticks / 2)
        return TimeRange(start: cut - half, end: cut - half + duration)
    }

    /// "a → b", "Start of b" or "End of a".
    var description: String {
        switch (outgoing, incoming) {
        case let (a?, b?): "\(a.name) → \(b.name)"
        case let (nil, b?): "Start of \(b.name)"
        case let (a?, nil): "End of \(a.name)"
        default: ""
        }
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
        /// How much of a clip a transition covers, from its full (unshortened) duration.
        func share(of transition: Transition) -> Time {
            transition.outgoingClipID == nil || transition.incomingClipID == nil
                ? transition.duration : Time(ticks: transition.duration.ticks / 2)
        }
        var result: [PlacedTransition] = []
        for transition in transitions where isValid(transition) {
            let outgoing = transition.outgoingClipID.flatMap { byID[$0] }
            let incoming = transition.incomingClipID.flatMap { byID[$0] }
            let involved = [outgoing, incoming].compactMap { $0 }
            var duration = involved.map(\.duration).reduce(transition.duration, min)
            // Share each clip between the transitions at its two ends.
            let mine = share(of: Transition(kind: transition.kind, duration: duration,
                                            outgoingClipID: transition.outgoingClipID, incomingClipID: transition.incomingClipID))
            let overlaps = involved.contains { clip in
                let other = transitions.first {
                    $0.id != transition.id && ($0.incomingClipID == clip.id || $0.outgoingClipID == clip.id)
                }
                return other.map { share(of: $0) + mine > clip.duration } ?? false
            }
            if overlaps {
                duration = (involved.map(\.duration).min() ?? duration).scaled(by: 0.5)
            }
            duration = max(duration, Transition.minimumDuration)
            let cut = incoming?.start ?? outgoing?.end ?? .zero
            result.append(PlacedTransition(transition: transition, outgoing: outgoing, incoming: incoming,
                                           cut: cut, duration: duration))
        }
        return result.sorted { $0.cut < $1.cut }
    }

    /// Whether a transition's clips still exist and its cut or edge still holds:
    /// clips on a cut touch, and an open edge has nothing touching it.
    func isValid(_ transition: Transition) -> Bool {
        let outgoing = transition.outgoingClipID.flatMap { id in clips.first { $0.id == id } }
        let incoming = transition.incomingClipID.flatMap { id in clips.first { $0.id == id } }
        switch (transition.outgoingClipID, transition.incomingClipID) {
        case (_?, _?):
            guard let outgoing, let incoming else { return false }
            return outgoing.end == incoming.start
        case (nil, _?):
            guard let incoming else { return false }
            return isOpen(start: incoming)
        case (_?, nil):
            guard let outgoing else { return false }
            return isOpen(end: outgoing)
        case (nil, nil):
            return false
        }
    }

    func isOpen(start clip: Clip) -> Bool { !clips.contains { $0.id != clip.id && $0.end == clip.start } }
    func isOpen(end clip: Clip) -> Bool { !clips.contains { $0.id != clip.id && $0.start == clip.end } }

    /// How far a clip's media has to extend past its start and end to cover its transitions.
    func transitionHandles(for clipID: UUID) -> (lead: Time, tail: Time) {
        var lead = Time.zero, tail = Time.zero
        for placed in placedTransitions() {
            let half = placed.cut - placed.range.start
            let rest = placed.range.end - placed.cut
            // Edge transitions play within their clip and need no extra media.
            guard !placed.isEdge else { continue }
            if placed.incoming?.id == clipID { lead = half }
            if placed.outgoing?.id == clipID { tail = rest }
        }
        return (lead, tail)
    }
}

nonisolated extension ProjectState {
    /// Drops transitions whose clips were deleted, or whose cut or open edge no
    /// longer holds (clips moved apart, or something now touches an open edge).
    mutating func pruneTransitions() {
        for index in tracks.indices where !tracks[index].transitions.isEmpty {
            let track = tracks[index]
            tracks[index].transitions.removeAll { !track.isValid($0) }
        }
    }

    /// Adds (or replaces) the transition on a cut between two touching clips
    /// (both IDs), or on a clip's open start (`incoming` only) or end (`outgoing` only).
    @discardableResult
    mutating func addTransition(_ kind: TransitionKind, between outgoingID: UUID?, and incomingID: UUID?,
                                duration: Time = Transition.defaultDuration) -> UUID? {
        guard let anyID = outgoingID ?? incomingID, let t = trackIndex(ofClip: anyID), tracks[t].kind.isVisual else { return nil }
        if let incomingID, trackIndex(ofClip: incomingID) != t { return nil }
        if let outgoingID, trackIndex(ofClip: outgoingID) != t { return nil }
        let transition = Transition(kind: kind, duration: duration, outgoingClipID: outgoingID, incomingClipID: incomingID)
        guard tracks[t].isValid(transition) else { return nil }
        tracks[t].transitions.removeAll { $0.outgoingClipID == outgoingID && $0.incomingClipID == incomingID }
        tracks[t].transitions.append(transition)
        return transition.id
    }

    /// The cut or open clip edge nearest `time` on a track, within `tolerance`.
    /// For an open edge one of the clips is nil.
    func cut(onTrack index: Int, near time: Time, tolerance: Time) -> (outgoing: Clip?, incoming: Clip?, time: Time)? {
        guard tracks.indices.contains(index) else { return nil }
        let track = tracks[index]
        var slots: [(outgoing: Clip?, incoming: Clip?, time: Time)] = []
        for clip in track.clips {
            if let before = track.clips.first(where: { $0.id != clip.id && $0.end == clip.start }) {
                slots.append((before, clip, clip.start))
            } else {
                slots.append((nil, clip, clip.start))
            }
            if track.isOpen(end: clip) { slots.append((clip, nil, clip.end)) }
        }
        func distance(_ slot: (outgoing: Clip?, incoming: Clip?, time: Time)) -> Int64 {
            abs((slot.time - time).ticks)
        }
        guard let best = slots.min(by: { distance($0) < distance($1) }), distance(best) <= tolerance.ticks else { return nil }
        return best
    }

    func transition(_ id: UUID) -> (trackIndex: Int, transition: Transition)? {
        for (index, track) in tracks.enumerated() {
            if let found = track.transitions.first(where: { $0.id == id }) { return (index, found) }
        }
        return nil
    }
}
