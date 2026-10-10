import AppKit

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
