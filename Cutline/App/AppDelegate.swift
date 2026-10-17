import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The UI is designed for a single dark look regardless of system settings.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Projects are created from the launch window, never as untitled documents.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        // Clears out cache files for old versions of media and ones unused for months.
        DiskCache.pruneAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isRunningTests { Updater.shared.checkAutomatically() }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting during an export asks first, then cancels it and removes partial files.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let queue = ExportQueue.shared
        guard queue.hasActiveJobs else { return .terminateNow }
        let count = queue.jobs.filter { !$0.status.isFinished }.count
        let alert = NSAlert()
        alert.messageText = count == 1 ? "An export is still running" : "\(count) exports are still running or queued"
        alert.informativeText = "Quitting cancels them and deletes the unfinished files."
        alert.addButton(withTitle: "Keep Exporting")
        alert.addButton(withTitle: "Quit and Cancel Exports")
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task {
            await queue.cancelAllAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
