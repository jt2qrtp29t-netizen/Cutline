# Cutline

A native video editor for macOS, written in Swift and SwiftUI with no third-party dependencies.

![Cutline's Edit tab: clip adjustments on the left, the preview in the middle, media on the right and a multi-track timeline below](screenshots/edit.png)

## Download

This is the **Sequoia edition** (the `sequoia` branch): it runs on **macOS 15 Sequoia and later**, on Apple silicon and Intel Macs. Get it from [Releases](https://github.com/jt2qrtp29t-netizen/Cutline/releases): look for **Cutline X.Y for Sequoia**, open **Cutline-Sequoia-X.Y.dmg** and drag Cutline onto Applications. On macOS 27 with Apple silicon, use the main edition (the `main` branch) instead.

Cutline isn't notarized by Apple, so the first time you open it macOS blocks it: click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway**. After that, Cutline updates itself (**Cutline → Check for Updates…**), with no more Open Anyway.

## What it does

Cutline is organized into tabs (⌘1–⌘8):

- **Edit**: a multi-track timeline with trimming, linking, locking, keyframes, speed changes and speed ramps (with frame blending and pitch-kept or tape-style audio), crop and transforms, and optimized and proxy media.
- **Effects**: animate any clip parameter with keyframes, and transitions between clips.
- **Color**: color wheels, curves, LUTs and scopes.
- **Audio**: a mixer, loudness metering, fades, pitch and ducking, with smooth, click-free scrubbing.
- **Captions**: on-device transcription (Apple's Speech framework) with word timing, editable transcripts, styled burned-in captions and `.srt` export.
- **Animate**: animated titles and graphics made with [Manim](https://www.manim.community), either from no-code templates (titles, lower thirds, score bugs, counters, countdowns and more) or from your own Python scripts. They're rendered with a transparent background over your footage.
- **Playground**: a sandbox copy of your edit for trying ideas without touching the real project.
- **Export**: H.264, HEVC and ProRes 422 exports, plus **Make Thumbnail**, which picks the best frames with Apple's Vision framework and, optionally, a local AI model through [Ollama](https://ollama.com). Nothing leaves your Mac.

## Screenshots

| | |
|---|---|
| ![Effects tab: transitions and keyframe animation of clip parameters, with the curve editor](screenshots/effects.png) **Effects**: transitions and keyframes | ![Color tab: lift, gamma, gain and offset wheels, basic controls and a waveform scope](screenshots/color.png) **Color**: wheels, curves and scopes |
| ![Audio tab: mixer, loudness meter with a normalize target, and track effects](screenshots/audio.png) **Audio**: mixer and loudness | ![Captions tab: transcript, caption grouping and style settings, burn-in and .srt export](screenshots/captions.png) **Captions**: transcripts and styled captions |
| ![Animate tab: the Title template with its text, look and animation settings and a transparent preview](screenshots/animate.png) **Animate**: Manim templates and scripts | ![Playground tab: a sandbox timeline with generators, effects like RGB Split and a custom shader, and snapshots](screenshots/playground.png) **Playground**: a sandbox for ideas |
| ![Export tab: presets such as YouTube 1080p 60, video and audio settings, captions and an estimate](screenshots/export.png) **Export**: presets and settings | ![Parameters window, General tab: welcome window, automatic update checks with Check Now, and watching for missing media](screenshots/parameters.png) **Parameters**: settings, including updates |
| ![Keyboard Shortcuts window with a search field](screenshots/keyboard-shortcuts.png) **Keyboard Shortcuts** | ![Changelog window listing each version's changes with Feature and Bug Fix tags](screenshots/changelog.png) **Changelog**: what changed in each version |

## Requirements

- macOS 15 Sequoia or later (Apple silicon or Intel)
- Xcode with the macOS 27 SDK (Swift 6); the app is built for macOS 15

Optional tools, run as separate programs on your Mac and only needed for their features:

- **Manim** for the Animate tab: `brew install cairo pango ffmpeg`, then `pip3 install manim`. LaTeX (for example MacTeX) is needed for the Equation template only.
- **Ollama** with a vision model (such as `ollama pull qwen2.5vl:3b`) for AI thumbnail picks.

## Building

```sh
git clone <this repository>
cd Cutline
open Cutline.xcodeproj
```

Then build and run the **Cutline** scheme in Xcode. From the command line:

```sh
xcodebuild -project Cutline.xcodeproj -scheme Cutline build
xcodebuild -project Cutline.xcodeproj -scheme Cutline test
```

Tests that need Manim or Ollama skip themselves when those tools aren't installed.

## Security

Found a security problem? Please report it privately from the [Security tab](https://github.com/jt2qrtp29t-netizen/Cutline/security) rather than in a public issue. See [SECURITY.md](SECURITY.md) for what's covered.

## License

Cutline is free software, released under the [GNU General Public License v3.0](LICENSE). You can use, study, change and share it. If you distribute a changed version, it must also be released under the GPL with its source code.
