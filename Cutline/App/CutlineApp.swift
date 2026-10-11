import SwiftUI

enum WindowID {
    static let launch = "launch"
    static let shortcuts = "shortcuts"
    static let changelog = "changelog"
}

/// True when the app is only hosting unit tests: no windows are opened then, so
/// mouse activity over a test-host window can't interfere with a test run.
let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

@main
struct CutlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Welcome to Cutline", id: WindowID.launch) {
            LaunchView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(isRunningTests || !AppSettings.shared.showWelcomeAtLaunch ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        DocumentGroup(allowCreating: false) { (document: CutlineDocument) in
            EditorView(document: document)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        } makeDocument: { _, _ in
            CutlineDocument()
        }
        .defaultSize(width: WindowMetrics.defaultWidth, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands { CutlineCommands() }

        Window("Keyboard Shortcuts", id: WindowID.shortcuts) {
            KeyboardShortcutsView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 520, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Changelog", id: WindowID.changelog) {
            ChangelogView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .defaultSize(width: 540, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            ParametersView()
        }
    }
}
