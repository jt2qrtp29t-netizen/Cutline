import Foundation

/// Finds the nearest snap target for a set of moving edges.
nonisolated enum SnapEngine {
    struct Result: Equatable {
        /// Amount to add to the moving edges.
        var offset: Time
        /// The timeline position that was snapped to (for drawing a guide).
        var target: Time
    }

    /// Candidate snap points: the playhead, markers, time zero and every clip edge
    /// except those of the clips being edited.
    static func points(in state: ProjectState, playhead: Time?, excluding excluded: Set<UUID>) -> [Time] {
        var points: [Time] = [.zero]
        if let playhead { points.append(playhead) }
        points.append(contentsOf: state.markers.map(\.time))
        for clip in state.allClips where !excluded.contains(clip.id) {
            points.append(clip.start)
            points.append(clip.end)
        }
        return points
    }

    /// Returns the smallest adjustment that puts any of `edges` on any of `points`,
    /// if one is within `threshold`.
    static func snap(edges: [Time], to points: [Time], threshold: Time) -> Result? {
        var best: Result?
        for edge in edges {
            for point in points {
                let distance = point - edge
                guard abs(distance.ticks) <= threshold.ticks else { continue }
                if best == nil || abs(distance.ticks) < abs(best!.offset.ticks) {
                    best = Result(offset: distance, target: point)
                }
            }
        }
        return best
    }
}
