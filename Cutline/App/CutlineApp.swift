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
                .cutlineAppearance()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(isRunningTests || !AppSettings.shared.showWelcomeAtLaunch ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        // File → New is replaced in CutlineCommands; projects are made from the launch window.
        DocumentGroup(newDocument: { CutlineDocument() }) { file in
            EditorView(document: file.document)
                .cutlineAppearance()
        }
        .defaultSize(width: WindowMetrics.defaultWidth, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands { CutlineCommands() }

        Window("Keyboard Shortcuts", id: WindowID.shortcuts) {
            KeyboardShortcutsView()
                .cutlineAppearance()
        }
        .defaultSize(width: 520, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Changelog", id: WindowID.changelog) {
            ChangelogView()
                .cutlineAppearance()
        }
        .defaultSize(width: 540, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            ParametersView()
        }
    }
}
