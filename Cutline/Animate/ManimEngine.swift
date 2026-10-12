import CryptoKit
import Foundation

/// Runs Manim (installed on this Mac, not bundled) to render animations: a script and
/// one of its scenes, at a size and frame rate, with a transparent background so it can
/// sit over video. Renders are cached on disk by everything that affects them.
nonisolated enum ManimEngine {
    struct Installation: Sendable, Equatable {
        /// The `manim` command.
        let executable: URL
        let version: String
    }

    enum Quality: String, Sendable, Codable, CaseIterable {
        /// Small and quick (a quarter of the size, at most 30 fps): for live previews.
        case preview
        /// The project's full size and frame rate.
        case full
    }

    struct Request: Sendable, Hashable {
        var script: String
        var scene: String
        var width: Int
        var height: Int
        var frameRate: Double
        var transparent = true
        var quality = Quality.full
        /// Values handed to the script as data (templates read them; never pasted into code).
        var parameters: [String: String] = [:]

        /// The size and rate actually rendered (previews are smaller and slower).
        var renderSize: (width: Int, height: Int, fps: Double) {
            guard quality == .preview else { return (width, height, frameRate) }
            // Even sizes (video encoders need them), a quarter of the area.
            let w = max(2, (width / 2) & ~1), h = max(2, (height / 2) & ~1)
            return (w, h, min(frameRate, 30))
        }
    }

    enum Failure: LocalizedError, Equatable {
        case notInstalled
        case sceneNotFound(String)
        case failed(String)
        case noOutput

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Manim isn't installed on this Mac."
            case let .sceneNotFound(name): "The script has no scene called “\(name)”."
            case let .failed(detail): detail
            case .noOutput: "Manim finished without making a video (does the scene play any animations?)."
            }
        }
    }

    // MARK: Finding Manim

    /// Where `manim` usually is. Apps opened from the Dock don't get Terminal's PATH,
    /// so the common install places are checked as well as PATH.
    static func candidateLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]) -> [URL] {
        var dirs = (environmentPath ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
                 home.appendingPathComponent(".pyenv/shims").path]
        let frameworks = "/Library/Frameworks/Python.framework/Versions"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []).sorted(by: >)
        dirs += versions.map { "\(frameworks)/\($0)/bin" }
        let userPython = home.appendingPathComponent("Library/Python").path
        let userVersions = ((try? FileManager.default.contentsOfDirectory(atPath: userPython)) ?? []).sorted(by: >)
        dirs += userVersions.map { "\(userPython)/\($0)/bin" }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0).appendingPathComponent("manim") }
    }

    /// The installed Manim, if any (its version from `manim --version`).
    static func find() async -> Installation? {
        for url in candidateLocations() where FileManager.default.isExecutableFile(atPath: url.path) {
            guard let output = try? await run(url, ["--version"], timeout: 30), output.status == 0 else { continue }
            let text = output.stdout + output.stderr
            let version = text.firstMatch(of: /v?(\d+\.\d+(?:\.\d+)?)/).map { String($0.1) } ?? "?"
            return Installation(executable: url, version: version)
        }
        return nil
    }

    // MARK: Scenes

    /// Scene classes defined in a script, in order (classes deriving from something ending in "Scene").
    static func scenes(in script: String) -> [String] {
        script.matches(of: /(?m)^class\s+([A-Za-z_]\w*)\s*\(\s*([\w.]*Scene)\s*[,)]/).map { String($0.1) }
    }

    // MARK: Rendering

    static var cacheFolder: URL { DiskCache.animations.folder }

    /// A name for everything the result depends on.
    static func cacheKey(_ request: Request, version: String) -> String {
        let size = request.renderSize
        let parameters = request.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1}")
        let text = "v1|\(version)|\(request.scene)|\(size.width)x\(size.height)@\(size.fps)|\(request.transparent)|\(parameters)|\(request.script)"
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The rendered movie if it's cached.
    static func cached(_ request: Request, installation: Installation) -> URL? {
        let url = cacheFolder.appendingPathComponent("\(cacheKey(request, version: installation.version)).mov")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        DiskCache.touch(url)
        return url
    }

    /// Renders the scene (or returns the cached render). `progress` gets 0…1 within the
    /// current animation and its number, as Manim reports them. Cancelling the task stops Manim.
    static func render(_ request: Request, installation: Installation,
                       progress: @escaping @Sendable (_ animation: Int, _ fraction: Double) -> Void = { _, _ in }) async throws -> URL {
        if let cached = cached(request, installation: installation) { return cached }
        guard scenes(in: request.script).contains(request.scene) else { throw Failure.sceneNotFound(request.scene) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("cutline-manim-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let scriptURL = work.appendingPathComponent("animation.py")
        try request.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        // Template values as data: the script reads CUTLINE_PARAMETERS (a JSON file).
        let parametersURL = work.appendingPathComponent("parameters.json")
        try JSONSerialization.data(withJSONObject: request.parameters, options: [.sortedKeys]).write(to: parametersURL)

        // PNG frames (with transparency), made into ProRes 4444 here: Manim's own transparent
        // movies use QuickTime Animation, which current macOS can't decode.
        let size = request.renderSize
        var arguments = ["render", scriptURL.path, request.scene, "--format", "png", "--media_dir", work.appendingPathComponent("media").path,
                         "--resolution", "\(size.width),\(size.height)", "--frame_rate", String(format: "%g", size.fps),
                         "--disable_caching", "-o", "frame", "--progress_bar", "display"]
        if request.transparent { arguments.append("--transparent") }
        let output = try await run(installation.executable, arguments, timeout: 1_800,
                                   environment: ["CUTLINE_PARAMETERS": parametersURL.path],
                                   onStderr: { line in
                                       if let p = parseProgress(line) { progress(p.animation, p.fraction) }
                                   })
        guard output.status == 0 else { throw Failure.failed(errorSummary(output.stderr + output.stdout)) }
        let frames = (fm.enumerator(at: work.appendingPathComponent("media"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !frames.isEmpty else { throw Failure.noOutput }
        try Task.checkCancellation()
        try fm.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let destination = cacheFolder.appendingPathComponent("\(cacheKey(request, version: installation.version)).mov")
        let partial = cacheFolder.appendingPathComponent("partial-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: partial) }
        try await ManimMovieWriter.write(frames: frames, fps: size.fps, width: size.width, height: size.height,
                                         alpha: request.transparent, to: partial)
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        try fm.moveItem(at: partial, to: destination)
        return destination
    }

    /// "Animation 2: Write(Text('GOAL')):  45%|…" → (2, 0.45).
    static func parseProgress(_ line: String) -> (animation: Int, fraction: Double)? {
        guard let match = line.firstMatch(of: /Animation\s+(\d+).*?(\d{1,3})%/),
              let animation = Int(match.1), let percent = Double(match.2) else { return nil }
        return (animation, min(percent, 100) / 100)
    }

    /// The useful end of Manim's output on failure: the Python error and where it happened.
    static func errorSummary(_ text: String) -> String {
        // Rich draws boxes around tracebacks; keep the meaningful lines.
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "│╭╰─╮╯ ").union(.whitespaces)) }
            .filter { !$0.isEmpty }
        // The error itself: the last line that looks like "SomeError: message".
        let error = lines.last { $0.range(of: #"^[A-Za-z_.]*(Error|Exception)\b"#, options: .regularExpression) != nil }
        // Where: the last mention of the user's script line.
        let location = lines.last { $0.contains("animation.py") && $0.contains("line") }
            ?? lines.last { $0.contains("animation.py:") }
        let line = location.flatMap { $0.firstMatch(of: /(?:line\s+|animation\.py:)(\d+)/).map { "line \($0.1)" } }
        switch (error, line) {
        case let (error?, line?): return "\(error) (\(line))"
        case let (error?, nil): return error
        default: return lines.suffix(4).joined(separator: "\n")
        }
    }

    // MARK: Processes

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a command and waits for it, streaming stderr lines to `onStderr`. Cancelling the
    /// calling task (or the timeout) terminates the process.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, environment: [String: String] = [:],
                    onStderr: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // The usual tool locations (LaTeX, Homebrew), which apps opened from the Dock lack.
        env["PATH"] = ([executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/Library/TeX/texbin",
                        "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + (env["PATH"]?.split(separator: ":").map(String.init) ?? []))
            .joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        // Rich progress bars need a width; keep them on one line.
        env["COLUMNS"] = "200"
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let collector = OutputCollector(onStderr: onStderr)
        outPipe.fileHandleForReading.readabilityHandler = { handle in collector.add(handle.availableData, toError: false) }
        errPipe.fileHandleForReading.readabilityHandler = { handle in collector.add(handle.availableData, toError: true) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { finished in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.add(outPipe.fileHandleForReading.readDataToEndOfFile(), toError: false)
                    collector.add(errPipe.fileHandleForReading.readDataToEndOfFile(), toError: true)
                    let (out, err) = collector.text
                    if collector.timedOut {
                        continuation.resume(throwing: Failure.failed("Manim took too long (over \(Int(timeout / 60)) minutes)."))
                    } else if Task.isCancelled || finished.terminationReason == .uncaughtSignal && collector.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: Output(status: finished.terminationStatus, stdout: out, stderr: err))
                    }
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure.failed("Manim couldn't be started (\(error.localizedDescription))."))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        collector.timedOut = true
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            collector.cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}

/// Collects a process's output from the pipes' threads.
nonisolated private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private var pendingLine = ""
    private let onStderr: @Sendable (String) -> Void
    var cancelled = false
    var timedOut = false

    init(onStderr: @escaping @Sendable (String) -> Void) { self.onStderr = onStderr }

    func add(_ data: Data, toError: Bool) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            if toError {
                err.append(data)
                // Progress bars rewrite their line with carriage returns.
                pendingLine += String(decoding: data, as: UTF8.self)
                let parts = pendingLine.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                lines = Array(parts.dropLast())
                pendingLine = parts.last ?? ""
            } else {
                out.append(data)
            }
        }
        for line in lines where !line.isEmpty { onStderr(line) }
    }

    var text: (String, String) {
        lock.withLock { (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) }
    }
}
