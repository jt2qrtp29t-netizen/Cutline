import CryptoKit
import Foundation

/// A Cutline release on GitHub, as the updater sees it.
nonisolated struct SoftwareRelease: Equatable, Sendable {
    struct Download: Equatable, Sendable {
        let name: String
        let url: URL
        let size: Int
        /// Hex SHA-256, from GitHub's own record of the file.
        let sha256: String
    }

    /// "5.2"
    let version: String
    let title: String
    /// The release notes (Markdown), without the manual install steps.
    let notes: String
    let page: URL
    let zip: Download

    enum ParseError: LocalizedError {
        case notARelease, noDownload(String), noChecksum

        var errorDescription: String? {
            switch self {
            case .notARelease: "GitHub didn't send a release."
            case .noDownload(let name): "The release has no \(name) to download."
            case .noChecksum: "GitHub has no checksum for the download, so it can't be checked."
            }
        }
    }

    /// Sequoia edition: its releases share the repository with the main edition's, so
    /// they're told apart by tag ("sequoia-v5.4") and download ("Cutline-Sequoia-5.4.zip").
    /// They're never GitHub's "latest" release, which belongs to the main edition.
    static let tagPrefix = "sequoia-v"
    static func zipName(for version: String) -> String { "Cutline-Sequoia-\(version).zip" }

    /// Reads GitHub's list of releases (api.github.com/repos/…/releases) and picks the
    /// newest published Sequoia edition release.
    static func parse(_ data: Data) throws -> SoftwareRelease {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let digest: String?
            let browser_download_url: URL
        }
        struct Release: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { throw ParseError.notARelease }
        let candidates = releases.filter { !$0.draft && !$0.prerelease && $0.tag_name.hasPrefix(tagPrefix) }
        guard let release = candidates.max(by: { isNewer($1.tag_name.dropFirst(tagPrefix.count).description,
                                                         than: $0.tag_name.dropFirst(tagPrefix.count).description) }) else {
            throw ParseError.notARelease
        }
        let version = String(release.tag_name.dropFirst(tagPrefix.count))
        let zipName = zipName(for: version)
        guard let zip = release.assets.first(where: { $0.name == zipName }) else { throw ParseError.noDownload(zipName) }
        guard let digest = zip.digest, digest.hasPrefix("sha256:") else { throw ParseError.noChecksum }
        return SoftwareRelease(version: version, title: release.name ?? "Cutline \(version)",
                               notes: whatsNew(release.body ?? ""), page: release.html_url,
                               zip: Download(name: zip.name, url: zip.browser_download_url, size: zip.size,
                                             sha256: String(digest.dropFirst("sha256:".count)).lowercased()))
    }

    /// The notes up to the manual install steps (the updater does those).
    static func whatsNew(_ body: String) -> String {
        var lines: [Substring] = []
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## Install") { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether version `a` is newer than `b` ("5.10" is newer than "5.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

/// Downloads a release, checks it, and swaps it in for the running app.
nonisolated enum SoftwareInstaller {
    enum Failure: LocalizedError {
        case translocated, notWritable(String), wrongSize, wrongChecksum, unpack(String), notCutline(String), signature(String), helper(String)

        var errorDescription: String? {
            switch self {
            case .translocated:
                "Cutline is running from the disk image or Downloads. Drag it into the Applications folder, open it from there, and try again."
            case .notWritable(let folder):
                "Cutline can't replace itself in “\(folder)” (no permission). Download the new version from GitHub and drag it into Applications instead."
            case .wrongSize, .wrongChecksum:
                "The download doesn't match GitHub's record of the file, so it wasn't installed. Try again later."
            case .unpack(let detail): "The download couldn't be unpacked (\(detail))."
            case .notCutline(let detail): "The download isn't the expected Cutline (\(detail)), so it wasn't installed."
            case .signature(let detail): "The new version's signature is damaged (\(detail)), so it wasn't installed."
            case .helper(let detail): "The installer couldn't start (\(detail))."
            }
        }
    }

    /// Whether Cutline can replace the app at `bundle` in place.
    static func checkInstallable(_ bundle: URL) throws {
        // macOS runs apps opened straight from Downloads or a disk image from a hidden,
        // read-only copy ("translocation").
        if bundle.path.contains("/AppTranslocation/") { throw Failure.translocated }
        let folder = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path), FileManager.default.isWritableFile(atPath: bundle.path) else {
            throw Failure.notWritable(folder.path)
        }
    }

    /// Downloads the zip into `folder`, reporting 0…1 as it arrives, and checks it
    /// against GitHub's size and checksum.
    static func download(_ file: SoftwareRelease.Download, into folder: URL, session: URLSession,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let tracker = DownloadProgress(progress)
        let (temporary, response) = try await session.download(from: file.url, delegate: tracker)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let destination = folder.appendingPathComponent(file.name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size == file.size else { throw Failure.wrongSize }
        guard try sha256(of: destination) == file.sha256 else { throw Failure.wrongChecksum }
        return destination
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Passes a download's progress on as it arrives.
    private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?

        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let report = report
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in report(progress.fractionCompleted) }
        }
    }

    /// Unpacks the zip and checks the app inside: the same app (bundle identifier), the
    /// promised version, an intact signature. Returns the new app.
    static func unpack(_ zip: URL, expecting version: String, bundleIdentifier: String) throws -> URL {
        let folder = zip.deletingLastPathComponent().appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: folder)
        let unzip = try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        guard unzip.status == 0 else { throw Failure.unpack(unzip.output) }
        let app = folder.appendingPathComponent("Cutline.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw Failure.notCutline("no Cutline.app inside")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else { throw Failure.notCutline("a different app") }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw Failure.notCutline("version \(info["CFBundleShortVersionString"] as? String ?? "?") instead of \(version)")
        }
        let check = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard check.status == 0 else { throw Failure.signature(check.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return app
    }

    /// Waits for process `$1` to quit (up to a minute; if it doesn't, nothing changes),
    /// moves the old app (`$2`) aside, moves the new one (`$3`) into its place (putting the
    /// old one back if that fails), then opens it unless `$4` is "stay".
    static let helperScript = """
    #!/bin/zsh
    pid=$1; old=$2; new=$3; relaunch=$4
    for i in {1..120}; do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
    kill -0 $pid 2>/dev/null && exit 1
    aside="${new:h}/previous-${old:t}"
    rm -rf "$aside"
    mv "$old" "$aside" || exit 2
    if ! mv "$new" "$old"; then
        mv "$aside" "$old"
        [ "$relaunch" = stay ] || /usr/bin/open -n "$old"
        exit 3
    fi
    rm -rf "$aside"
    [ "$relaunch" = stay ] || /usr/bin/open -n "$old"
    exit 0
    """

    /// Starts the helper; it outlives Cutline. Returns it (tests wait on it).
    @discardableResult
    static func launchHelper(waitingFor pid: Int32, replacing old: URL, with new: URL, relaunch: Bool = true) throws -> Process {
        let script = new.deletingLastPathComponent().appendingPathComponent("install.sh")
        do {
            try helperScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path, String(pid), old.path, new.path, relaunch ? "open" : "stay"]
            try process.run()
            return process
        } catch {
            throw Failure.helper(error.localizedDescription)
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
