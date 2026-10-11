import Foundation

/// What each version of Cutline added, newest first, shown in the Changelog window.
/// Add an entry with every update; a test checks the newest one matches the app version.
enum Changelog {
    /// What kind of update a version is: new features, bug fixes, or both.
    enum Tag: String, CaseIterable, Identifiable {
        case feature = "FEATURE"
        case bugFix = "BUG FIX"
        var id: String { rawValue }
    }

    struct Entry: Identifiable {
        let version: String
        let title: String
        let tags: [Tag]
        let changes: [String]
        var id: String { version }
    }

    static let entries: [Entry] = [
        Entry(version: "4.4", title: "Smooth speed changes", tags: [.bugFix], changes: [
            "Fixed: speed changes could make the preview lag, stutter or freeze. Changing a speed ramp made every filmstrip thumbnail on the clip ask for a new frame on every step of the drag, and with recordings that only store a full frame every few seconds (games, phones) each one meant decoding seconds of video, keeping the video decoder busy long after the drag.",
            "Thumbnails now wait for the end of a drag (showing the nearest frame meanwhile), are made at most three at a time, newest first, and skip requests for tiles that have scrolled away or moved on.",
            "Fixed: ramped and Frame Blend clips were cut into a piece per frame for the player, forcing the decoder to start over again and again. Constant speeds are one piece again (as before 4.0), and ramps a few long pieces within an eighth of a frame of the curve: 2–3× faster to decode.",
        ]),
        Entry(version: "4.3", title: "Clean live scrubbing", tags: [.feature, .bugFix], changes: [
            "Fixed: dragging the playhead could play a rough, low sound over the audio. Each time the scrub audio caught up with the playhead, the jump was timed from a guess of where the sound card was; when the guess was off it cut straight to the new spot with no crossfade, many times a second.",
            "Scrubbing works as it did in v1.8 again: the scrub head lives on the audio thread and moves at the exact sample being played, so every catch-up is a smooth 10 ms crossfade (still landing where the waveform matches).",
            "Fixed: pausing a drag for just over a tenth of a second and moving on could click, because the sound jumped back to full volume in the middle of fading out. It now fades back up from where it was.",
            "Scrubbing never makes the audio thread wait for the rest of the app or free memory, so a busy Mac is less likely to make it drop out.",
            "Changelog entries are tagged FEATURE, BUG FIX, or both.",
        ]),
        Entry(version: "4.2", title: "Keyframe lane fixes", tags: [.bugFix], changes: [
            "Fixed: the keyframe lane under the timeline (in every tab) showed no keyframes for clips wider than the visible timeline, so long clips or zoomed-in views looked empty even at their start. Diamonds now always sit exactly under their times.",
            "Fixed: pressing Delete with a keyframe selected in the Edit or Audio tab's lane (such as a Softness or Speed keyframe) deleted the whole clip. It now deletes the keyframe, as in Effects and Color.",
        ]),
        Entry(version: "4.1", title: "Clean scrubbing", tags: [.bugFix], changes: [
            "Fixed: dragging the playhead could add a muffled, fluttering sound over the audio. When the scrub head had to catch up with the playhead, it crossfaded between two unrelated points of the waveform, which partly cancelled each other many times a second.",
            "The scrub head now lands each catch-up within 10 ms of the playhead at the spot whose waveform matches what was just playing, so the sound stays full and steady at any drag speed.",
        ]),
        Entry(version: "4.0", title: "Edit Adjustments: speed ramps and crop softness", tags: [.feature, .bugFix], changes: [
            "Speed in the Edit tab (video and audio clips) now has a lock, like Position. Locked, the clip plays at one speed exactly as before. Unlock it and an End value appears, starting equal to Start, so nothing changes until you move it. The clip then ramps smoothly from Start to End. Locking again goes back to a constant speed.",
            "Speed Change, just below, keyframes the speed for multi-point ramps, with ◆ and ◀︎ ▶︎ like other animated values, and its keyframes appear in the lane under the timeline. Start and End are its first and last keyframes.",
            "A clip keeps the same piece of its media whatever its speed curve: its length follows the curve and the clips after it move along. Linked video and audio share one curve and stay in sync, and cutting a ramped clip keeps its speed and picture continuous.",
            "Slow motion for video: Nearest repeats source frames; Frame Blend (the default for new clips) mixes neighboring frames for smoother slow motion. Clips from older projects keep Nearest, so they look exactly as before.",
            "Preserve Pitch for audio: on, voices keep their pitch at any speed; off, pitch follows speed like tape or a record. Semitones and cents still add on top. Ramped and tape-style sound is rendered ahead of time from the same curve as the picture, changes speed smoothly with no clicks, and is identical in playback and export. Fades and volume stay in timeline time.",
            "A warning shows when a clip's speed goes below 25% or above 400%, where picture and sound lose quality.",
            "Crop Softness (0–100%) in the Crop section feathers the cropped edges so they fade out, with keyframes, reset and undo. 0% looks exactly as before.",
            "Fixed: pressing Play on a busy Mac could do nothing if the player took more than 3 seconds to get ready; it now waits up to 10.",
        ]),
        Entry(version: "3.9", title: "Window size", tags: [.feature, .bugFix], changes: [
            "Project windows can't be made narrower than 1536 points (about 60% of a 27″ display), so the Effects, Color and Audio tabs always have room for their panels beside the preview. On a smaller screen the limit is the screen's width.",
            "New project windows open 1680 points wide (or as wide as the screen).",
            "The Audio tab also fits its columns to the window, and in a narrow mixer the track strips, master and loudness panel scroll together, so a track strip is never hidden.",
            "Fixed: the background check for missing files could report every file as changed after its records were refreshed, making playback drop and reload all prepared audio for nothing.",
        ]),
        Entry(version: "3.8", title: "Audio tab", tags: [.feature], changes: [
            "A new Audio tab (⌘4) between Color and Playground: a mixer, the preview, the selected clip's and track's settings and effects, and audio keyframe lanes under the timeline.",
            "One audio engine for playback, scrubbing and export: each clip, track and the master run through the same chain and the same calculations, so what you hear is exactly what's exported. Everything runs at 48 kHz stereo; sources are converted once on the way in. Existing clips sound exactly as before.",
            "Mixer: a strip per audio track with a dB fader, pan, mute, solo (solo overrides mute; several tracks can be soloed) and a live peak meter with a clip light, plus a master strip. Double-click a fader for 0 dB; hold ⌥ for fine control.",
            "Clip tools: fade-in and fade-out handles on audio clips with linear, equal-power or logarithmic curves, crossfades between touching clips, clip gain in dB, and waveforms that follow gain, volume and fades.",
            "Track effects, in any order and each with a bypass: a 4-band equalizer with low and high cut, compressor, noise gate, de-esser, limiter and a basic noise reduction. Presets for Voice (commentary), Game audio, Music bed and Radio / telephone set ordinary values you can keep editing.",
            "Loudness: a master meter with momentary, short-term and integrated LUFS and true peak, and Normalize for a clip, a track or the whole project (−14 LUFS for YouTube, −16 or any target), applied as a gain you can see and change. A master limiter.",
            "Ducking: a game or music track goes down automatically while the voice track talks, with threshold, amount, attack and release, worked out ahead of time so every playback and export is the same.",
            "Volume, pan and every effect setting can be keyframed, with easing. Fader, mute, solo and setting changes glide over a few milliseconds, so nothing clicks; playback fades in and out on play and pause.",
            "Tabs are now Edit, Effects, Color, Audio, Playground, Export (⌘1–⌘6).",
        ]),
        Entry(version: "3.7", title: "Export finishing fix", tags: [.feature, .bugFix], changes: [
            "Fixed: an export could sit at 100% saying “Rendering” for a long time, ignoring Cancel and holding up the queue. Network optimization was copying the whole finished file in small pieces with no progress.",
            "Network optimization now copies in large blocks (about half a gigabyte in a fraction of a second), shows its own progress, and stops at once when canceled. It’s skipped for ProRes masters, which aren’t streamed.",
            "Fixed: making optimized or proxy media could occasionally stop partway and never finish.",
            "The queue and the live view say what an export is doing (mixing audio, rendering, finishing the file, optimizing for network), and Cancel shows “Canceling…” right away.",
        ]),
        Entry(version: "3.6", title: "Live render view", tags: [.feature], changes: [
            "While an export runs, the Export tab’s viewer shows the frames being exported, live, framed exactly as in the file (cropped or letterboxed for vertical and square exports), with the frame number, timecode, progress and time left.",
            "Frames are shown a dozen times a second and prepared off the export’s thread, so exports don’t slow down. The eye button hides them; “Show Frames” over the preview brings them back.",
        ]),
        Entry(version: "3.5", title: "Performance", tags: [.feature, .bugFix], changes: [
            "Accurate export time estimates, based on measured encoder speeds, how much work each frame is (layers, grades, Labs effects), and how long your own exports take.",
            "Faster Encoding now keeps the quality: it raises the bitrate 20% to make up for the encoder’s faster mode, which is still about 1.9× faster. It’s only offered for HEVC, the codec it speeds up.",
            "Network Optimization in the Export tab (on by default): the movie’s index goes at the start of the file, so it starts playing while it downloads or uploads.",
            "Twice as fast drawing of video frames in 4K: the GPU now reads frames in the decoder’s own format instead of converting each one first. 10-bit footage keeps its full precision, and clips with transparency still work.",
            "Optimized media (full size ProRes 422) and proxy media (half size ProRes 422 Proxy): right-click a clip in the media bin to create them, with progress and status tags on each item. They keep every frame time of the original, so they stand in anywhere on the timeline.",
            "Choose what playback reads with the new film button next to the mute button: Original, Optimized or Proxy (falling back to the original when there’s no copy). The viewer says when it shows copies, and exports always use the original files.",
            "A Performance tab in Parameters: what this Mac’s media engine decodes and encodes in hardware, the playback media choice, creating optimized or proxy media on import, cache sizes with Clear buttons, and resetting learned export speeds.",
            "Smarter rendering caches: color grades, compiled shaders and text images now drop the least recently used entries instead of starting over when full, so an animated grade no longer forces every other clip’s grade to be rebuilt each frame. Thumbnails are capped by memory.",
            "Waveforms are saved to disk, so reopened projects draw them at once. Cache files made from older versions of a file are removed automatically, as are audio previews and waveforms unused for two months.",
            "Fixed: exports could freeze when several frames were drawn or several exports ran at once, and an export could fail with “the audio mix stopped early” on a busy Mac.",
        ]),
        Entry(version: "3.4", title: "Faster exports", tags: [.feature], changes: [
            "4K exports are up to about 1.7× faster: frames are now rendered several at a time, and a new Faster Encoding option (on by default) lets the hardware encoder favor speed.",
            "Turn off Faster Encoding under Video in the Export tab for the very best quality at the same bitrate.",
        ]),
        Entry(version: "3.3", title: "Export tab", tags: [.feature], changes: [
            "Export presets: YouTube 4K 60, YouTube 1080p 60, Social Vertical and Square (crop or fit), Quick Preview, ProRes Master, and Custom.",
            "Custom settings for size, frame rate, codec (H.264, HEVC, ProRes 422), container, quality, hardware encoding and audio (AAC bitrate, sample rate, stereo or mono), saved with the project.",
            "Exports use the same renderer as the preview (grades, keyframes, text, transitions, Labs effects and shaders) and the same audio mix as playback, frame-exact and without drift.",
            "Files are written to a temporary file first and only moved into place when complete. A Labs effect that fails is left out with a warning instead of stopping the export.",
            "An export queue that runs in the background from a frozen copy of the timeline, with progress, time remaining, Cancel (which removes the unfinished file), a notification when done, and no sleeping Mac mid-export. Quitting during an export asks first.",
            "Export the Playground too: its own settings, a “-playground” file name, and each variant alone or as separate files. Missing media or LUTs are flagged before starting.",
            "The Export tab: source, range (whole timeline, in/out or selected clips) and presets on the left, the frame being exported in the middle, and settings, size and time estimates, Save As and the queue on the right. Show in Finder, Open and Add to Media when done.",
        ]),
        Entry(version: "3.2", title: "Playground tab", tags: [.feature], changes: [
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
        Entry(version: "3.1", title: "Color keyframes on the timeline", tags: [.feature], changes: [
            "The Color tab shows its keyframes in a lane under the timeline, where they can be selected, dragged to retime and deleted.",
            "Each tab now lists its own keyframes: motion in Effects, color in Color.",
        ]),
        Entry(version: "3.0", title: "Color tab", tags: [.feature], changes: [
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
        Entry(version: "2.9", title: "Changelog", tags: [.feature], changes: [
            "New Changelog window listing what every version added. Open it with the list icon in the top bar or from the Help menu.",
        ]),
        Entry(version: "2.8", title: "Longer default transitions", tags: [.feature], changes: [
            "New transitions are 1.25 seconds long by default (used by fresh installs and Restore Defaults).",
        ]),
        Entry(version: "2.7", title: "Parameters and Keyboard Shortcuts", tags: [.feature], changes: [
            "Parameters window (⌘,) with General, Timeline, Playback and Mouse settings.",
            "Settings for: showing the welcome window at launch, watching for missing media, new transition length, snapping in new projects, snap distance, following the playhead, ⌥-drag precision, scrub audio and muting.",
            "Option to reverse the direction of thumb-wheel tab switching, or turn it off.",
            "Keyboard Shortcuts window (⌘/ or the keyboard icon in the top bar), with search.",
        ]),
        Entry(version: "2.6", title: "Thumb-wheel fix", tags: [.bugFix], changes: [
            "Tab switching now works for every flick of a smooth-scrolling thumb wheel, not just the first one after a click.",
        ]),
        Entry(version: "2.5", title: "Thumb wheel and frame-by-frame scrubbing", tags: [.feature], changes: [
            "Scroll sideways (e.g. an MX Master thumb wheel) to switch between tabs.",
            "Hold ⌥ while dragging the playhead to move it one frame at a time.",
        ]),
        Entry(version: "2.4", title: "Edge transitions and offline media", tags: [.feature], changes: [
            "Transitions can go on the start of a track’s first clip or the end of its last clip (any open clip edge), fading from or to black.",
            "Missing media is detected while you work: a red “Media Offline” frame in the viewer, a warning banner, and offline badges in the timeline and media bin.",
            "Relink… finds a moved file, and relinks other missing files in the same folder at the same time.",
        ]),
        Entry(version: "2.3", title: "Transitions", tags: [.feature], changes: [
            "Cross Dissolve, Dip to Black, Slide (left, right, up, down) and Zoom between touching clips.",
            "Drag a transition from the Effects tab onto a cut, or click it to use the cut at the playhead.",
            "Adjustable length; select a transition on the timeline to change or delete it.",
        ]),
        Entry(version: "2.2", title: "Animation presets", tags: [.feature], changes: [
            "Presets in the Effects tab: Fade, Slide, Zoom Pop, Bounce and Shake, to animate in or out.",
            "Gameplay presets at the playhead: Zoom Punch and Screen Shake.",
            "Curve editor values sit in their own column so the curve never covers them.",
        ]),
        Entry(version: "2.1", title: "Tabs and keyframes", tags: [.feature], changes: [
            "Tab bar with Edit, Effects, Color, Playground and Export.",
            "Keyframes for position, zoom, rotation, opacity, yaw and pitch, with easing curves.",
            "Effects tab with keyframe controls, a keyframe lane on the timeline and a curve editor.",
            "App icon.",
        ]),
        Entry(version: "2.0", title: "Text tracks and fonts", tags: [.feature, .bugFix], changes: [
            "Text clips live on their own text tracks (T1, T2…); new projects start with one.",
            "Every Font Book font in the font menu, including downloadable ones.",
            "Fixed a crash when deleting a track.",
        ]),
        Entry(version: "1.9", title: "Text", tags: [.feature], changes: [
            "Text clips: up to 200 characters, with size, position, color, stroke (inside, outside or center) and font.",
        ]),
        Entry(version: "1.8", title: "Clean scrub audio", tags: [.bugFix], changes: [
            "Scrubbing plays clean audio at normal pitch, whatever the drag speed.",
        ]),
        Entry(version: "1.7", title: "Scrub audio fix", tags: [.bugFix], changes: [
            "Removed the muffled sound under scrub audio.",
        ]),
        Entry(version: "1.6", title: "Clip mute and solo", tags: [.bugFix], changes: [
            "Mute and Solo in a clip’s right-click menu apply to the selected clips only, not the whole track.",
        ]),
        Entry(version: "1.5", title: "Playback fixes", tags: [.feature, .bugFix], changes: [
            "Solo and Mute in the right-click menu of audio clips.",
            "Deleting markers works reliably.",
            "Space pauses as well as plays.",
            "Less noise when scrubbing.",
        ]),
        Entry(version: "1.4", title: "Scrubbing", tags: [.feature, .bugFix], changes: [
            "Hear the audio under the playhead while dragging it.",
            "The timeline keeps scrolling when you drag the playhead past its edge.",
            "⌥⌘L works for linking and unlinking.",
            "Fixed a green bar that sometimes appeared on V1.",
        ]),
        Entry(version: "1.3", title: "Motion and audio controls", tags: [.feature], changes: [
            "Start and end positions to move a clip across the frame over time.",
            "Solo, mute and height for each track.",
            "Pitch (semitones and cents) and pan for audio.",
            "Flip horizontal and vertical, plus yaw and pitch.",
            "Version number in the top bar.",
        ]),
        Entry(version: "1.2", title: "Linking and locking", tags: [.feature], changes: [
            "Link and unlink clips (right-click or ⌥⌘L).",
            "Lock clips, change clip speed and duration.",
            "A universal mute button.",
            "New projects start with V1 and A1; drag a clip below the tracks to make a new one.",
            "More precise zoom and position adjustments, finer still with ⌥.",
        ]),
        Entry(version: "1.1", title: "Audio and adjustments", tags: [.feature], changes: [
            "Title bar with the project name.",
            "Delete tracks; audio tracks with support for many audio formats.",
            "Zoom and crop (top, bottom, left, right) for clips; the Inspector is now called Adjustments.",
            "Sharper, more compact media bin thumbnails.",
            "Files with video and sound are split into separate video and audio clips; tracks can be locked.",
        ]),
        Entry(version: "1.0", title: "First version", tags: [.feature], changes: [
            "Project creation with name, location, resolution and frame rate, plus recent projects.",
            "Editor with inspector, preview, media bin and a multi-track timeline with thumbnails.",
            "Drag and drop from Finder; move, trim and snap clips; play with Space; scrub with the playhead.",
            "Blade (⌘B) and markers (⌘M) with names and colors.",
        ]),
    ]
}
