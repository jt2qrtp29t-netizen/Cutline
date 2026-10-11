import AppKit
import Foundation
import Testing
@testable import Cutline

/// The test host shares the app's preferences, so every test puts the user's values back.
@MainActor struct ParametersTests {
    private func preserving(_ body: () throws -> Void) rethrows {
        let s = AppSettings.shared
        let saved = (s.snapByDefault, s.snapDistance, s.fineScrubPointsPerFrame, s.transitionLength,
                     s.reverseTabScrolling, s.scrollSwitchesTabs)
        defer {
            s.snapByDefault = saved.0
            s.snapDistance = saved.1
            s.fineScrubPointsPerFrame = saved.2
            s.transitionLength = saved.3
            s.reverseTabScrolling = saved.4
            s.scrollSwitchesTabs = saved.5
        }
        try body()
    }

    @Test func settingsAreSaved() {
        preserving {
            AppSettings.shared.snapDistance = 13
            #expect(UserDefaults.standard.double(forKey: "timeline.snapDistance") == 13)
            AppSettings.shared.reverseTabScrolling = true
            #expect(UserDefaults.standard.bool(forKey: "mouse.reverseTabScrolling"))
        }
    }

    @Test func newProjectsStartWithTheChosenSnapping() {
        preserving {
            AppSettings.shared.snapByDefault = false
            #expect(!EditorController(store: ProjectStore(state: ProjectState())).snappingEnabled)
            AppSettings.shared.snapByDefault = true
            #expect(EditorController(store: ProjectStore(state: ProjectState())).snappingEnabled)
        }
    }

    @Test func optionDragPrecisionFollowsTheSetting() {
        preserving {
            var state = ProjectState()
            state.tracks[0].clips = [Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero,
                                          duration: Time(seconds: 20), sourceStart: .zero)]
            let editor = EditorController(store: ProjectStore(state: state))
            let layout = TimelineLayout(pixelsPerSecond: 10, tracks: state.tracks)
            editor.playback.seek(to: Time(seconds: 5))
            AppSettings.shared.fineScrubPointsPerFrame = 20
            let x = layout.x(for: Time(seconds: 5))
            editor.dragPlayhead(viewportX: x, contentX: x, layout: layout, modifiers: .option)
            editor.dragPlayhead(viewportX: x + 45, contentX: x + 45, layout: layout, modifiers: .option)
            let fps = editor.fps
            #expect(editor.playback.currentTime == (Time(seconds: 5) + Time(seconds: 2.0 / Double(fps))).snappedToFrame(fps: fps),
                    "45 pt at 20 pt per frame is 2 frames")
            editor.endPlayheadDrag()
        }
    }

    @Test func newTransitionsUseTheChosenLength() {
        preserving {
            AppSettings.shared.transitionLength = 0.5
            var state = ProjectState()
            let a = Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
            let b = Clip(id: UUID(), mediaID: UUID(), name: "b", start: Time(seconds: 4), duration: Time(seconds: 4), sourceStart: .zero)
            state.tracks[0].clips = [a, b]
            let editor = EditorController(store: ProjectStore(state: state))
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.store.undoManager = undo
            undo.beginUndoGrouping()
            editor.addTransition(.crossDissolve, at: TransitionDropTarget(trackIndex: 0, outgoingID: a.id, incomingID: b.id,
                                                                          cut: Time(seconds: 4)))
            undo.endUndoGrouping()
            #expect(editor.state.tracks[0].transitions.first?.duration == Time(seconds: 0.5))
        }
    }

    @Test func defaultTransitionLengthIsOneAndAQuarterSeconds() {
        // Fresh installs and Restore Defaults use this value too.
        #expect(Transition.defaultDuration == Time(seconds: 1.25))
    }

    @Test func reversingSwapsTheTabDirection() {
        #expect(TabScrollGesture.direction(1, reversed: false) == 1)
        #expect(TabScrollGesture.direction(1, reversed: true) == -1)
        #expect(TabScrollGesture.direction(-1, reversed: true) == 1)
    }

    @Test func everyMenuShortcutIsListed() {
        let keys = Set(ShortcutList.groups.flatMap(\.items).map(\.keys))
        for shortcut in ["⌘N", "⌘I", "⇧⌘E", "⌘B", "⌥⌘L", "⇧⌘L", "⇧⌘N", "⇧⌘T", "⌘M", "⇧⌘M", "⌥⌘M", "⌘,", "⌘/", "Space", "⌥⌘C", "⌥⌘V"] {
            #expect(keys.contains(shortcut), "\(shortcut) is missing from the Keyboard Shortcuts window")
        }
    }

    @Test func changelogCoversEveryVersionUpToThisOne() {
        let versions = Changelog.entries.map(\.version)
        // Newest first, one entry per version from 1.0 up to the version being built.
        let built = Bundle(for: EditorController.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(versions.first == built, "add a Changelog entry for v\(built ?? "?")")
        let numbers = versions.compactMap(Double.init)
        #expect(numbers == numbers.sorted(by: >) && numbers.last == 1.0)
        #expect(Set(versions).count == versions.count)
        #expect(Changelog.entries.allSatisfy { !$0.changes.isEmpty })
        // Every version is tagged FEATURE, BUG FIX or both, and a version listing a fix says so.
        for entry in Changelog.entries {
            #expect(!entry.tags.isEmpty && Set(entry.tags).count == entry.tags.count, "v\(entry.version) tags")
            if entry.changes.contains(where: { $0.hasPrefix("Fixed") }) {
                #expect(entry.tags.contains(.bugFix), "v\(entry.version) lists a fix")
            }
        }
    }
}
