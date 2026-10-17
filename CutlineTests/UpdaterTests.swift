import CryptoKit
import Foundation
import Testing
@testable import Cutline

/// Answers in place of GitHub.
nonisolated final class FakeGitHub: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (status: Int, body: Data)] = [:]

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGitHub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let answer = Self.responses[request.url!.absoluteString] ?? (404, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct UpdaterTests {
    static func releaseJSON(version: String, zipSize: Int = 1_000, sha: String? = String(repeating: "ab", count: 32),
                            prerelease: Bool = false) -> Data {
        var asset: [String: Any] = ["name": "Cutline-\(version).zip", "size": zipSize,
                                    "browser_download_url": "https://github.com/x/Cutline/releases/download/v\(version)/Cutline-\(version).zip"]
        if let sha { asset["digest"] = "sha256:\(sha)" }
        let release: [String: Any] = [
            "tag_name": "v\(version)", "name": "Cutline \(version)", "draft": false, "prerelease": prerelease,
            "html_url": "https://github.com/x/Cutline/releases/tag/v\(version)",
            "body": "## Better things\r\n\r\n- Fixed: one thing.\r\n- Added **another**.\r\n\r\n## Install\r\n\r\n1. Download it.",
            "assets": [["name": "Cutline-\(version).dmg", "size": 5, "digest": "sha256:00", "browser_download_url": "https://x/a.dmg"], asset],
        ]
        return try! JSONSerialization.data(withJSONObject: release)
    }

    @Test func versionsCompareAsNumbers() {
        #expect(SoftwareRelease.isNewer("5.2", than: "5.1"))
        #expect(SoftwareRelease.isNewer("5.10", than: "5.9"))
        #expect(SoftwareRelease.isNewer("6.0", than: "5.9"))
        #expect(!SoftwareRelease.isNewer("5.1", than: "5.1"))
        #expect(!SoftwareRelease.isNewer("5.0", than: "5.1"))
        #expect(SoftwareRelease.isNewer("5.1.1", than: "5.1"))
    }

    @Test func readsGitHubsAnswer() throws {
        let release = try SoftwareRelease.parse(Self.releaseJSON(version: "5.3", zipSize: 1234))
        #expect(release.version == "5.3" && release.zip.name == "Cutline-5.3.zip" && release.zip.size == 1234)
        #expect(release.zip.sha256 == String(repeating: "ab", count: 32), "GitHub's own checksum")
        #expect(release.notes == "## Better things\n\n- Fixed: one thing.\n- Added **another**.", "without the manual install steps")
        #expect(throws: SoftwareRelease.ParseError.self) { try SoftwareRelease.parse(Self.releaseJSON(version: "5.3", sha: nil)) }
        #expect(throws: SoftwareRelease.ParseError.self) { try SoftwareRelease.parse(Self.releaseJSON(version: "5.3", prerelease: true)) }
        #expect(throws: SoftwareRelease.ParseError.self) { try SoftwareRelease.parse(Data("{}".utf8)) }
    }

    /// The real defaults are shared with the user's own Cutline (same app): put them back.
    private func keepingSettings(_ body: () async throws -> Void) async rethrows {
        let settings = AppSettings.shared
        let saved = (settings.checkForUpdates, settings.lastUpdateCheck, settings.skippedUpdateVersion)
        defer { (settings.checkForUpdates, settings.lastUpdateCheck, settings.skippedUpdateVersion) = saved }
        try await body()
    }

    private func settle(_ updater: Updater) async throws {
        for _ in 0..<100 where updater.phase == .checking || updater.phase == .idle {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func offersNewerVersionsOnly() async throws {
        try await keepingSettings {
            let updater = Updater(session: FakeGitHub.session())
            let newer = SoftwareRelease.isNewer("99.0", than: AppVersion.short)
            #expect(newer)
            FakeGitHub.responses[Updater.feed.absoluteString] = (200, Self.releaseJSON(version: "99.0"))
            AppSettings.shared.skippedUpdateVersion = ""
            updater.check(userInitiated: false)
            try await settle(updater)
            guard case .available(let release) = updater.phase else { Issue.record("\(updater.phase)"); return }
            #expect(release.version == "99.0")
            #expect(AppSettings.shared.lastUpdateCheck != nil)

            // Skipped: not offered at launch, but still when asked.
            updater.skip(release)
            updater.check(userInitiated: false)
            try await Task.sleep(for: .milliseconds(300))
            #expect(updater.phase == .idle)
            updater.check(userInitiated: true)
            try await settle(updater)
            #expect(updater.phase == .available(release))

            // The same version: up to date (only said when asked).
            FakeGitHub.responses[Updater.feed.absoluteString] = (200, Self.releaseJSON(version: AppVersion.short))
            updater.check(userInitiated: true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(updater.phase == .upToDate)

            // Offline or GitHub trouble: quiet at launch, explained when asked.
            FakeGitHub.responses[Updater.feed.absoluteString] = (500, Data())
            updater.check(userInitiated: false)
            try await Task.sleep(for: .milliseconds(300))
            #expect(updater.phase == .idle)
            updater.check(userInitiated: true)
            try await Task.sleep(for: .milliseconds(300))
            if case .failed = updater.phase {} else { Issue.record("\(updater.phase)") }

            // At launch, once a day at most.
            FakeGitHub.responses[Updater.feed.absoluteString] = (200, Self.releaseJSON(version: "99.0"))
            AppSettings.shared.skippedUpdateVersion = ""
            AppSettings.shared.lastUpdateCheck = .now
            updater.close()
            updater.checkAutomatically()
            try await Task.sleep(for: .milliseconds(300))
            #expect(updater.phase == .idle, "checked recently")
            AppSettings.shared.checkForUpdates = false
            AppSettings.shared.lastUpdateCheck = nil
            updater.checkAutomatically()
            try await Task.sleep(for: .milliseconds(300))
            #expect(updater.phase == .idle, "turned off")
        }
    }

    /// A zip of this very app (the test host), as a release would hold it.
    private func zipOfThisApp(in folder: URL) throws -> (url: URL, data: Data) {
        let zip = folder.appendingPathComponent("source.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", Bundle.main.bundleURL.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return (zip, try Data(contentsOf: zip))
    }

    private func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    @Test func downloadsAreCheckedBeforeInstalling() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, data) = try zipOfThisApp(in: folder)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = URL(string: "https://github.com/x/Cutline/releases/download/test/Cutline.zip")!
        FakeGitHub.responses[url.absoluteString] = (200, data)
        let session = FakeGitHub.session()
        let identifier = try #require(Bundle.main.bundleIdentifier)

        // The right file: unpacked, checked, and not marked for Gatekeeper (no Open Anyway).
        let good = SoftwareRelease.Download(name: "Cutline-\(AppVersion.short).zip", url: url, size: data.count, sha256: sha)
        let goodFolder = folder.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: goodFolder, withIntermediateDirectories: true)
        let fractions = Fractions()
        let downloaded = try await SoftwareInstaller.download(good, into: goodFolder, session: session) { fractions.add($0) }
        #expect(fractions.values.last == 1)
        let app = try SoftwareInstaller.unpack(downloaded, expecting: AppVersion.short, bundleIdentifier: identifier)
        #expect(app.lastPathComponent == "Cutline.app")
        #expect(!hasQuarantine(downloaded) && !hasQuarantine(app), "downloaded by Cutline itself: no Open Anyway")

        // Tampered with (or cut short): refused.
        for bad in [SoftwareRelease.Download(name: "a.zip", url: url, size: data.count, sha256: String(repeating: "0", count: 64)),
                    SoftwareRelease.Download(name: "b.zip", url: url, size: data.count + 1, sha256: sha)] {
            await #expect(throws: SoftwareInstaller.Failure.self) {
                try await SoftwareInstaller.download(bad, into: folder, session: session) { _ in }
            }
        }
        // Not the promised version, or not Cutline: refused.
        #expect(throws: SoftwareInstaller.Failure.self) { try SoftwareInstaller.unpack(downloaded, expecting: "99.0", bundleIdentifier: identifier) }
        #expect(throws: SoftwareInstaller.Failure.self) { try SoftwareInstaller.unpack(downloaded, expecting: AppVersion.short, bundleIdentifier: "com.other.App") }
    }

    @Test func onlyAppsInAWritableFolderUpdateThemselves() throws {
        #expect(throws: SoftwareInstaller.Failure.self) {
            try SoftwareInstaller.checkInstallable(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Cutline.app"))
        }
        #expect(throws: SoftwareInstaller.Failure.self) { try SoftwareInstaller.checkInstallable(URL(fileURLWithPath: "/System/Applications/Cutline.app")) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
        let app = folder.appendingPathComponent("Cutline.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try SoftwareInstaller.checkInstallable(app)
    }

    /// The helper waits for Cutline to quit, swaps the apps, and puts the old one back
    /// if the swap fails.
    @Test func theHelperSwapsTheAppAfterCutlineQuits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func app(_ path: String, marker: String) throws -> URL {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try marker.write(to: url.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
            return url
        }
        func marker(_ url: URL) -> String? { try? String(contentsOf: url.appendingPathComponent("marker"), encoding: .utf8) }
        func running() throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["1"]
            try p.run()
            return p
        }

        let old = try app("Applications/Cutline.app", marker: "old")
        let new = try app("update/unpacked/Cutline.app", marker: "new")
        let cutline = try running()
        let helper = try SoftwareInstaller.launchHelper(waitingFor: cutline.processIdentifier, replacing: old, with: new, relaunch: false)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(marker(old) == "old", "nothing changes while Cutline is still running")
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        #expect(marker(old) == "new", "swapped in")
        #expect(!FileManager.default.fileExists(atPath: new.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("update/unpacked/previous-Cutline.app").path), "old copy cleaned up")

        // The new app is missing (swap fails): the old one goes back.
        let gone = folder.appendingPathComponent("update2/unpacked/Cutline.app")
        try FileManager.default.createDirectory(at: gone.deletingLastPathComponent(), withIntermediateDirectories: true)
        let again = try SoftwareInstaller.launchHelper(waitingFor: try running().processIdentifier, replacing: old, with: gone, relaunch: false)
        again.waitUntilExit()
        #expect(again.terminationStatus == 3 && marker(old) == "new", "the installed app is put back")
    }
}

nonisolated final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    func add(_ value: Double) { lock.withLock { list.append(value) } }
    var values: [Double] { lock.withLock { list } }
}
