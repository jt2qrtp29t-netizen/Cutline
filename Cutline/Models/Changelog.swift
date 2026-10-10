import Foundation

/// What each version of Cutline added, newest first, shown in the Changelog window.
/// Add an entry with every update; a test checks the newest one matches the app version.
enum Changelog {
    struct Entry: Identifiable {
        let version: String
        let title: String
        let changes: [String]
        var id: String { version }
    }

    static let entries: [Entry] = [
        Entry(version: "3.3", title: "Export tab", changes: [
            "Export presets: YouTube 4K 60, YouTube 1080p 60, Social Vertical and Square (crop or fit), Quick Preview, ProRes Master, and Custom.",
            "Custom settings for size, frame rate, codec (H.264, HEVC, ProRes 422), container, quality, hardware encoding and audio (AAC bitrate, sample rate, stereo or mono), saved with the project.",
        ]),
        Entry(version: "3.2", title: "Playground tab", changes: [
            "A sandbox for experiments: the Playground has its own timeline, undo history, selection and preview, and nothing in it can change your project.",
            "It’s saved on its own (not in the project file) and comes back when you reopen the project. Reset clears it after asking.",
            "Adjust, Effects and Color panels work on Playground clips, with an amber Sandbox badge so it’s never mistaken for the real timeline.",
            "Send to Playground (right-click a clip in Edit) copies clips with their grade, effects and keyframes. Copies are independent of the originals.",
            "Promote to Edit adds a Playground clip to your project as a new clip, or applies its settings to the original or the selected Edit clip, as one undo step.",
            "Variants: duplicate a clip into A, B, C… and compare them one at a time or side by side, then keep the best.",
            "Snapshots: save named checkpoints of the Playground and restore any of them.",
            "Labs: experiments you can switch on and off. Generators (Solid Color, Gradient, Noise, Color Bars) and effects (RGB Split & Glitch, Wave Warp, and a Custom Shader with editable Metal code), all with keyframable parameters.",
            "A failing experiment (like a shader that doesn’t compile) shows its error and the clip falls back to how it looked without it.",
        ]),
        Entry(version: "3.1", title: "Color keyframes on the timeline", changes: [
            "The Color tab shows its keyframes in a lane under the timeline, where they can be selected, dragged to retime and deleted.",
            "Each tab now lists its own keyframes: motion in Effects, color in Color.",
        ]),
        Entry(version: "3.0", title: "Color tab", changes: [
            "A new color grading engine on the GPU, with one fixed order: exposure, white balance, offset, lift/gamma/gain, contrast and saturation, curves, then LUT. Values are only clamped at the very end.",
            "Every color control can be keyframed, undone and saved. Older projects load and look exactly as before.",
            "Lift, Gamma, Gain and Offset color wheels in a 2×2 grid: drag to tint (⌥ for fine control), a master slider under each, double-click to reset, and one keyframe diamond per wheel.",
            "Basic controls: exposure, brightness, contrast, saturation, temperature, tint, highlights and shadows, each with keyframes.",
            "Exposure, brightness, contrast and saturation moved from the Edit tab to the Color tab.",
            "RGB curves (master, red, green, blue) with draggable points, and a hue vs saturation curve.",
            "LUTs: apply a .cube file with adjustable intensity. Invalid files show a clear error; a missing LUT shows a warning on the clip and the clip renders without it.",
            "Scopes: histogram, waveform and vectorscope of the frame in the viewer, with the grade applied, updating as you play or scrub.",
            "Before/after: hold B (or use the Before button) to see the ungraded picture.",
            "Copy Grade (⌥⌘C) and Paste Grade (⌥⌘V) between clips, Apply Grade to All Clips on Track, and resets for each section or the whole grade.",
        ]),
        Entry(version: "2.9", title: "Changelog", changes: [
            "New Changelog window listing what every version added. Open it with the list icon in the top bar or from the Help menu.",
        ]),
        Entry(version: "2.8", title: "Longer default transitions", changes: [
            "New transitions are 1.25 seconds long by default (used by fresh installs and Restore Defaults).",
        ]),
        Entry(version: "2.7", title: "Parameters and Keyboard Shortcuts", changes: [
            "Parameters window (⌘,) with General, Timeline, Playback and Mouse settings.",
            "Settings for: showing the welcome window at launch, watching for missing media, new transition length, snapping in new projects, snap distance, following the playhead, ⌥-drag precision, scrub audio and muting.",
            "Option to reverse the direction of thumb-wheel tab switching, or turn it off.",
            "Keyboard Shortcuts window (⌘/ or the keyboard icon in the top bar), with search.",
        ]),
        Entry(version: "2.6", title: "Thumb-wheel fix", changes: [
            "Tab switching now works for every flick of a smooth-scrolling thumb wheel, not just the first one after a click.",
        ]),
        Entry(version: "2.5", title: "Thumb wheel and frame-by-frame scrubbing", changes: [
            "Scroll sideways (e.g. an MX Master thumb wheel) to switch between tabs.",
            "Hold ⌥ while dragging the playhead to move it one frame at a time.",
        ]),
        Entry(version: "2.4", title: "Edge transitions and offline media", changes: [
            "Transitions can go on the start of a track’s first clip or the end of its last clip (any open clip edge), fading from or to black.",
            "Missing media is detected while you work: a red “Media Offline” frame in the viewer, a warning banner, and offline badges in the timeline and media bin.",
            "Relink… finds a moved file, and relinks other missing files in the same folder at the same time.",
        ]),
        Entry(version: "2.3", title: "Transitions", changes: [
            "Cross Dissolve, Dip to Black, Slide (left, right, up, down) and Zoom between touching clips.",
            "Drag a transition from the Effects tab onto a cut, or click it to use the cut at the playhead.",
            "Adjustable length; select a transition on the timeline to change or delete it.",
        ]),
        Entry(version: "2.2", title: "Animation presets", changes: [
            "Presets in the Effects tab: Fade, Slide, Zoom Pop, Bounce and Shake, to animate in or out.",
            "Gameplay presets at the playhead: Zoom Punch and Screen Shake.",
            "Curve editor values sit in their own column so the curve never covers them.",
        ]),
        Entry(version: "2.1", title: "Tabs and keyframes", changes: [
            "Tab bar with Edit, Effects, Color, Playground and Export.",
            "Keyframes for position, zoom, rotation, opacity, yaw and pitch, with easing curves.",
            "Effects tab with keyframe controls, a keyframe lane on the timeline and a curve editor.",
            "App icon.",
        ]),
        Entry(version: "2.0", title: "Text tracks and fonts", changes: [
            "Text clips live on their own text tracks (T1, T2…); new projects start with one.",
            "Every Font Book font in the font menu, including downloadable ones.",
            "Fixed a crash when deleting a track.",
        ]),
        Entry(version: "1.9", title: "Text", changes: [
            "Text clips: up to 200 characters, with size, position, color, stroke (inside, outside or center) and font.",
        ]),
        Entry(version: "1.8", title: "Clean scrub audio", changes: [
            "Scrubbing plays clean audio at normal pitch, whatever the drag speed.",
        ]),
        Entry(version: "1.7", title: "Scrub audio fix", changes: [
            "Removed the muffled sound under scrub audio.",
        ]),
        Entry(version: "1.6", title: "Clip mute and solo", changes: [
            "Mute and Solo in a clip’s right-click menu apply to the selected clips only, not the whole track.",
        ]),
        Entry(version: "1.5", title: "Playback fixes", changes: [
            "Solo and Mute in the right-click menu of audio clips.",
            "Deleting markers works reliably.",
            "Space pauses as well as plays.",
            "Less noise when scrubbing.",
        ]),
        Entry(version: "1.4", title: "Scrubbing", changes: [
            "Hear the audio under the playhead while dragging it.",
            "The timeline keeps scrolling when you drag the playhead past its edge.",
            "⌥⌘L works for linking and unlinking.",
            "Fixed a green bar that sometimes appeared on V1.",
        ]),
        Entry(version: "1.3", title: "Motion and audio controls", changes: [
            "Start and end positions to move a clip across the frame over time.",
            "Solo, mute and height for each track.",
            "Pitch (semitones and cents) and pan for audio.",
            "Flip horizontal and vertical, plus yaw and pitch.",
            "Version number in the top bar.",
        ]),
        Entry(version: "1.2", title: "Linking and locking", changes: [
            "Link and unlink clips (right-click or ⌥⌘L).",
            "Lock clips, change clip speed and duration.",
            "A universal mute button.",
            "New projects start with V1 and A1; drag a clip below the tracks to make a new one.",
            "More precise zoom and position adjustments, finer still with ⌥.",
        ]),
        Entry(version: "1.1", title: "Audio and adjustments", changes: [
            "Title bar with the project name.",
            "Delete tracks; audio tracks with support for many audio formats.",
            "Zoom and crop (top, bottom, left, right) for clips; the Inspector is now called Adjustments.",
            "Sharper, more compact media bin thumbnails.",
            "Files with video and sound are split into separate video and audio clips; tracks can be locked.",
        ]),
        Entry(version: "1.0", title: "First version", changes: [
            "Project creation with name, location, resolution and frame rate, plus recent projects.",
            "Editor with inspector, preview, media bin and a multi-track timeline with thumbnails.",
            "Drag and drop from Finder; move, trim and snap clips; play with Space; scrub with the playhead.",
            "Blade (⌘B) and markers (⌘M) with names and colors.",
        ]),
    ]
}
