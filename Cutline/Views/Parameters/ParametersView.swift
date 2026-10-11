import SwiftUI

/// The Parameters window (⌘,): app-wide settings, in tabs.
struct ParametersView: View {
    @AppStorage("parameters.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralParameters() }
            Tab("Timeline", systemImage: "timeline.selection", value: "timeline") { TimelineParameters() }
            Tab("Playback", systemImage: "play.circle", value: "playback") { PlaybackParameters() }
            Tab("Mouse", systemImage: "computermouse", value: "mouse") { MouseParameters() }
            Tab("Performance", systemImage: "gauge.with.dots.needle.67percent", value: "performance") { PerformanceParameters() }
        }
        .frame(width: 520)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

private struct GeneralParameters: View {
    @Bindable private var settings = AppSettings.shared
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Show the welcome window when Cutline opens", isOn: $settings.showWelcomeAtLaunch)
            }
            Section {
                Toggle("Watch for missing media", isOn: $settings.watchForOfflineMedia)
            } footer: {
                ParameterNote("Checks every couple of seconds for files that were moved, renamed or deleted, or are on a disk that was ejected. When off, files are only checked when you switch back to Cutline.")
            }
            Section {
                ParameterSlider(title: "New transition length", value: $settings.transitionLength,
                                range: AppSettings.transitionLengthRange, step: 0.05, format: "%.2f s")
            } footer: {
                ParameterNote("Used when you drag a transition onto a cut. You can change each transition’s length afterwards.")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restore all parameters to their defaults?", isPresented: $confirmReset) {
            Button("Restore Defaults", role: .destructive) { settings.resetToDefaults() }
        }
    }
}

private struct TimelineParameters: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Snapping on in newly opened projects", isOn: $settings.snapByDefault)
                ParameterSlider(title: "Snap distance", value: $settings.snapDistance,
                                range: AppSettings.snapDistanceRange, step: 1, format: "%.0f pt")
            } footer: {
                ParameterNote("How close clip edges, the playhead and markers must come before they snap together. ⇧⌘N turns snapping on or off in a project.")
            }
            Section {
                Toggle("Follow the playhead during playback", isOn: $settings.followPlayhead)
            } footer: {
                ParameterNote("Scrolls the timeline so the playhead stays in view while playing.")
            }
            Section {
                ParameterSlider(title: "⌥-drag precision", value: $settings.fineScrubPointsPerFrame,
                                range: AppSettings.fineScrubRange, step: 1, format: "%.0f pt per frame")
            } footer: {
                ParameterNote("While you hold ⌥ and drag the playhead, it moves one frame each time the pointer travels this far. Larger is finer.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackParameters: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Play audio while scrubbing", isOn: $settings.scrubAudio)
            } footer: {
                ParameterNote("Plays the sound under the playhead as you drag it.")
            }
            Section {
                Toggle("Mute all audio", isOn: $settings.isMuted)
            } footer: {
                ParameterNote("Silences playback in every project. Also in the Playback menu (⇧⌘M).")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MouseParameters: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Scroll sideways to switch tabs", isOn: $settings.scrollSwitchesTabs)
                Toggle("Reverse tab scrolling direction", isOn: $settings.reverseTabScrolling)
                    .disabled(!settings.scrollSwitchesTabs)
            } footer: {
                ParameterNote(settings.reverseTabScrolling
                    ? "Scrolling right moves to the tab on the left, and scrolling left to the tab on the right. Works with a mouse’s thumb wheel (like the MX Master) or a sideways trackpad swipe, anywhere except over the timeline."
                    : "Scrolling right moves to the tab on the right, and scrolling left to the tab on the left. Works with a mouse’s thumb wheel (like the MX Master) or a sideways trackpad swipe, anywhere except over the timeline.")
            }
        }
        .formStyle(.grouped)
    }
}

/// A labelled slider with its value shown on the right.
private struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 180)
                Text(String(format: format, value))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 100, alignment: .trailing)
            }
        }
    }
}

struct ParameterNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
