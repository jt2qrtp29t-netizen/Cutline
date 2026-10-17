import AppKit
import Observation
import SwiftUI

/// Checks GitHub for a newer Cutline, and installs it from inside the app: downloads
/// made by Cutline itself don't need Gatekeeper's Open Anyway again (only the first
/// install, from a browser download, does).
@Observable
final class Updater {
    static let shared = Updater()

    /// GitHub's latest release of Cutline.
    static let feed = URL(string: "https://api.github.com/repos/jt2qrtp29t-netizen/Cutline/releases/latest")!

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(SoftwareRelease)
        case downloading(SoftwareRelease, Double)
        case installing(SoftwareRelease)
        case failed(String, page: URL?)
    }

    private(set) var phase = Phase.idle

    @ObservationIgnored let session: URLSession
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(session: URLSession = .shared, settings: AppSettings = .shared) {
        self.session = session
        self.settings = settings
    }

    /// Where to ask. A local test server may stand in (launch argument
    /// `-updates.feedURL http://127.0.0.1:…`); nothing else can.
    var feedURL: URL {
        if let override = UserDefaults.standard.string(forKey: "updates.feedURL"), let url = URL(string: override),
           url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host()) {
            return url
        }
        return Self.feed
    }

    /// At launch: once a day at most, if automatic checks are on. Says nothing unless
    /// there's a new version the user hasn't skipped.
    func checkAutomatically() {
        guard settings.checkForUpdates else { return }
        if let last = settings.lastUpdateCheck, Date.now.timeIntervalSince(last) < 20 * 3600 { return }
        check(userInitiated: false)
    }

    /// Cutline → Check for Updates…: always answers, in the update window.
    func check(userInitiated: Bool) {
        guard task == nil else { if userInitiated { showWindow() }; return }
        if userInitiated { phase = .checking; showWindow() }
        task = Task {
            defer { task = nil }
            do {
                var request = URLRequest(url: feedURL, timeoutInterval: 30)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let release = try SoftwareRelease.parse(data)
                settings.lastUpdateCheck = .now
                if SoftwareRelease.isNewer(release.version, than: AppVersion.short) {
                    guard userInitiated || release.version != settings.skippedUpdateVersion else { phase = .idle; return }
                    phase = .available(release)
                    showWindow()
                    // End-to-end tests against a local feed: install at once, after this check ends.
                    if UserDefaults.standard.bool(forKey: "updates.installWithoutAsking"), feedURL != Self.feed {
                        Task { install(release) }
                    }
                } else {
                    phase = userInitiated ? .upToDate : .idle
                }
            } catch {
                phase = userInitiated
                    ? .failed("Couldn't check for updates: \(error.localizedDescription)", page: nil)
                    : .idle
            }
        }
    }

    func skip(_ release: SoftwareRelease) {
        settings.skippedUpdateVersion = release.version
        close()
    }

    func close() {
        if case .downloading = phase { task?.cancel() }
        phase = .idle
        window?.close()
    }

    /// Downloads and checks the new version, then quits; a helper swaps it in and
    /// relaunches. Quitting goes through the usual path (running exports ask first).
    func install(_ release: SoftwareRelease, bundle: URL = Bundle.main.bundleURL) {
        guard task == nil else { return }
        phase = .downloading(release, 0)
        task = Task {
            defer { task = nil }
            do {
                try SoftwareInstaller.checkInstallable(bundle)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let zip = try await SoftwareInstaller.download(release.zip, into: folder, session: session) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.phase { self.phase = .downloading(release, fraction) }
                    }
                }
                let identifier = Bundle.main.bundleIdentifier ?? "app.cutline.Cutline"
                let app = try await Task.detached {
                    try SoftwareInstaller.unpack(zip, expecting: release.version, bundleIdentifier: identifier)
                }.value
                phase = .installing(release)
                try SoftwareInstaller.launchHelper(waitingFor: ProcessInfo.processInfo.processIdentifier, replacing: bundle, with: app)
                NSApp.terminate(nil)
                // Still here a moment later: quitting was cancelled (e.g. Keep Exporting).
                try? await Task.sleep(for: .seconds(3))
                phase = .failed("Cutline didn't quit, so the update wasn't installed. Try again when you're ready.", page: nil)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription, page: release.page)
            }
        }
    }

    private func showWindow() {
        guard !isRunningTests else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: UpdateView(updater: self).preferredColorScheme(.dark).tint(Theme.accent))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = "Software Update"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// The update window: what's new and Install, progress, or what went wrong.
struct UpdateView: View {
    let updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.system(size: 15, weight: .semibold))
                    Text(subheadline)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.background)
    }

    private var headline: String {
        switch updater.phase {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "Cutline is up to date"
        case .available(let release), .downloading(let release, _), .installing(let release): "Cutline \(release.version) is available"
        case .failed: "Software Update"
        }
    }

    private var subheadline: String {
        switch updater.phase {
        case .upToDate: "You have the newest version, \(AppVersion.short)."
        case .available, .downloading, .installing: "You have \(AppVersion.short). Cutline updates itself and reopens; your projects are kept."
        default: ""
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            buttons { Button("OK") { updater.close() }.keyboardShortcut(.defaultAction) }
        case .available(let release):
            notes(release)
            buttons {
                Button("Skip This Version") { updater.skip(release) }
                Spacer()
                Button("Later") { updater.close() }.keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { updater.install(release) }.keyboardShortcut(.defaultAction)
            }
        case .downloading(let release, let fraction):
            notes(release)
            ProgressView(value: fraction) { Text("Downloading…").font(.system(size: 11)) }
            buttons { Spacer(); Button("Cancel") { updater.close() } }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing. Cutline will quit and reopen…").font(.system(size: 12))
            }
        case .failed(let message, let page):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sandbox)
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                if let page { Button("Open Download Page") { NSWorkspace.shared.open(page) } }
                Spacer()
                Button("Close") { updater.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { content() }.controlSize(.regular)
    }

    /// The release notes: "## " headings and "- " items, other lines as text.
    private func notes(_ release: SoftwareRelease) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(release.notes.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("## ") {
                        Text(line.dropFirst(3)).font(.system(size: 12.5, weight: .semibold)).padding(.top, 2)
                    } else if line.hasPrefix("- ") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(Theme.textTertiary)
                            Text(markdown(line.dropFirst(2)))
                        }
                    } else {
                        Text(markdown(line))
                    }
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(height: 200)
        .background(Theme.raised.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private func markdown(_ text: Substring) -> AttributedString {
        (try? AttributedString(markdown: String(text))) ?? AttributedString(String(text))
    }
}
