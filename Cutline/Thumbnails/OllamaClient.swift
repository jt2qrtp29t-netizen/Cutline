import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Talks to Ollama running on this Mac (http://127.0.0.1:11434): which models it has,
/// and asking a vision model about images. Nothing goes anywhere but the local server.
nonisolated struct OllamaClient: Sendable {
    var baseURL = URL(string: "http://127.0.0.1:11434")!
    /// For tests: answers requests in place of the network.
    var session: URLSession = .shared

    struct Model: Sendable, Equatable {
        let name: String
        let capabilities: [String]
        var canSeeImages: Bool { capabilities.contains("vision") }
    }

    enum Failure: LocalizedError, Equatable {
        case notRunning
        case noVisionModel(installed: [String])
        case badAnswer(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: "Ollama isn't running on this Mac."
            case let .noVisionModel(installed):
                installed.isEmpty
                    ? "Ollama has no models (if you moved its models folder, Ollama may still be looking in the old place)."
                    : "None of Ollama's models can look at images (it has \(installed.joined(separator: ", "))). Add one, e.g. qwen2.5vl:7b."
            case let .badAnswer(detail): "The model's answer couldn't be used (\(detail))."
            }
        }
    }

    /// Installed models with what they can do.
    func models() async throws -> [Model] {
        struct Tags: Decodable { struct M: Decodable { let name: String; let capabilities: [String]? }; let models: [M] }
        let data: Data
        do {
            var request = URLRequest(url: baseURL.appending(path: "api/tags"))
            request.timeoutInterval = 3
            (data, _) = try await session.data(for: request)
        } catch { throw Failure.notRunning }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else { throw Failure.notRunning }
        var result: [Model] = []
        for m in tags.models {
            // Older servers don't list capabilities in tags: ask for them.
            var capabilities = m.capabilities ?? []
            if m.capabilities == nil, let asked = try? await self.capabilities(of: m.name) { capabilities = asked }
            result.append(Model(name: m.name, capabilities: capabilities))
        }
        return result
    }

    private func capabilities(of model: String) async throws -> [String] {
        struct Show: Decodable { let capabilities: [String]? }
        var request = URLRequest(url: baseURL.appending(path: "api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = try JSONEncoder().encode(["model": model])
        let (data, _) = try await session.data(for: request)
        return (try JSONDecoder().decode(Show.self, from: data)).capabilities ?? []
    }

    /// The vision model to use: preferred families first (Qwen-VL, Gemma 3, Llama Vision…).
    func visionModel() async throws -> String {
        let installed = try await models()
        let seeing = installed.filter(\.canSeeImages).map(\.name)
        guard !seeing.isEmpty else { throw Failure.noVisionModel(installed: installed.map(\.name)) }
        let preference = ["qwen2.5vl", "qwen3-vl", "qwen2.5-vl", "gemma3", "llama3.2-vision", "llava"]
        return seeing.min { a, b in
            let ra = preference.firstIndex { a.hasPrefix($0) } ?? preference.count
            let rb = preference.firstIndex { b.hasPrefix($0) } ?? preference.count
            return ra < rb
        }!
    }

    /// One chat turn with images; the answer is JSON matching `schema`.
    /// Room the request needs: about 800 tokens per image (at 448 px) plus the prompt and answer.
    static func contextSize(images: Int, promptCharacters: Int) -> Int {
        let needed = images * 800 + promptCharacters / 3 + 1_024
        return min(max(8_192, ((needed + 4_095) / 4_096) * 4_096), 32_768)
    }

    func ask(model: String, prompt: String, images: [CGImage], schema: [String: Any], timeout: TimeInterval = 300) async throws -> Data {
        let encoded = images.compactMap { Self.jpeg($0, maxSide: 448)?.base64EncodedString() }
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": schema,
            // The default context (4K tokens) is too small for a dozen images.
            "options": ["temperature": 0.2, "num_ctx": Self.contextSize(images: encoded.count, promptCharacters: prompt.count)],
            // Stay loaded a while: a second try doesn't reload the model from disk.
            "keep_alive": "10m",
            "messages": [["role": "user", "content": prompt, "images": encoded]],
        ]
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do { (data, _) = try await session.data(for: request) } catch let error as URLError where error.code == .timedOut {
            throw Failure.badAnswer("it took too long")
        } catch { throw Failure.notRunning }
        // Errors come as {"error": "…"} or {"error": {"message": "…"}}.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] {
            let message = (error as? String) ?? ((error as? [String: Any])?["message"] as? String) ?? "\(error)"
            throw Failure.badAnswer(message)
        }
        struct Reply: Decodable { struct Message: Decodable { let content: String }; let message: Message? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure.badAnswer("not a chat reply") }
        guard let content = reply.message?.content.data(using: .utf8) else { throw Failure.badAnswer("empty") }
        return content
    }

    /// A JPEG no larger than `maxSide` (what the model looks at; small keeps it quick).
    static func jpeg(_ image: CGImage, maxSide: Int) -> Data? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// The three thumbnail picks, from the AI model or (without one) from Vision's ranking.
nonisolated struct ThumbnailPicks: Sendable {
    struct Pick: Sendable, Identifiable {
        let candidate: ThumbnailCandidate
        let reason: String
        var id: UUID { candidate.id }
    }

    let picks: [Pick]
    /// A short title the model suggests for the thumbnail, if asked and given.
    let title: String?
    /// The model that chose, or nil when Vision's ranking was used.
    let model: String?
    /// Why the AI model wasn't used, if it wasn't.
    let note: String?
}

/// Picks the best 3 of the shortlisted candidates with a local vision model.
nonisolated enum ThumbnailPicker {
    /// Frames rated below this by Vision (black, blank, badly blurred) are never offered to the model.
    static let minimumAesthetics = -0.5

    /// The rating a frame needs to be offered: well below the video's own best frames means
    /// blurred, blank or a transition. Relative, so darker footage (games) keeps its frames.
    static func aestheticsFloor(for candidates: [ThumbnailCandidate]) -> Double {
        let ranked = candidates.filter { !$0.isUtility }.map(\.aesthetics).sorted(by: >)
        guard ranked.count >= 3 else { return minimumAesthetics }
        return max(minimumAesthetics, ranked[2] - 0.6)
    }

    /// The answer's JSON schema (Ollama structured output). Built on demand: `[String: Any]` isn't Sendable.
    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "picks": ["type": "array", "items": ["type": "object", "properties": [
                "frame": ["type": "integer"], "reason": ["type": "string"],
            ], "required": ["frame", "reason"]]],
            "title": ["type": "string"],
        ],
        "required": ["picks"],
    ] }

    static func prompt(count: Int, context: String, wantsTitle: Bool) -> String {
        var text = """
        These \(count) images are frames from a video, numbered 1 to \(count) in the order given. \
        Choose the 3 that would make the best YouTube thumbnail: eye-catching, sharp, an expressive face or a clear \
        dramatic moment, readable at a small size, not a blurry transition or a menu screen. Prefer 3 that are different \
        from each other. Never choose a black, blank or nearly empty frame. For each, give its frame number and a \
        short reason (under 12 words).
        """
        if !context.isEmpty { text += "\nWhat is said in the video (for context): \(context)" }
        if wantsTitle { text += "\nAlso suggest a punchy thumbnail title of 2 to 5 words, in the video's language." }
        text += "\nAnswer as JSON: {\"picks\": [{\"frame\": n, \"reason\": \"…\"}], \"title\": \"…\"}."
        return text
    }

    /// The best 3 (fewer if there are fewer candidates). Any failure falls back to the
    /// candidates' own ranking, with a note saying why.
    static func pick(from candidates: [ThumbnailCandidate], context: String = "", wantsTitle: Bool = false,
                     client: OllamaClient = OllamaClient()) async -> ThumbnailPicks {
        let fallback = { (note: String?) in
            ThumbnailPicks(picks: candidates.prefix(3).map { .init(candidate: $0, reason: $0.reason) }, title: nil, model: nil, note: note)
        }
        // Only frames worth considering go to the model (no black, blank, blurry or
        // screenshot-like frames); with too few left there's nothing to choose between.
        let usable = candidates.filter { !$0.isUtility && $0.aesthetics > aestheticsFloor(for: candidates) }
        guard usable.count > 3 else {
            let ranked = usable + candidates.filter { c in !usable.contains { $0.id == c.id } }
            return ThumbnailPicks(picks: ranked.prefix(3).map { .init(candidate: $0, reason: $0.reason) }, title: nil, model: nil, note: nil)
        }
        let candidates = usable
        do {
            let model = try await client.visionModel()
            let data = try await client.ask(model: model, prompt: prompt(count: candidates.count, context: String(context.prefix(1_500)),
                                                                         wantsTitle: wantsTitle),
                                            images: candidates.map(\.image), schema: schema)
            struct Answer: Decodable { struct P: Decodable { let frame: Int; let reason: String }; let picks: [P]; let title: String? }
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
                throw OllamaClient.Failure.badAnswer("not the expected JSON")
            }
            // Valid, distinct frame numbers; topped up from the ranking if fewer than 3.
            var used = Set<Int>()
            var picks: [ThumbnailPicks.Pick] = []
            for p in answer.picks where (1...candidates.count).contains(p.frame) && used.insert(p.frame).inserted && picks.count < 3 {
                picks.append(.init(candidate: candidates[p.frame - 1], reason: p.reason.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            guard !picks.isEmpty else { throw OllamaClient.Failure.badAnswer("no usable frame numbers") }
            for (k, c) in candidates.enumerated() where picks.count < 3 && !used.contains(k + 1) {
                picks.append(.init(candidate: c, reason: c.reason))
            }
            let title = answer.title?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            return ThumbnailPicks(picks: picks, title: wantsTitle && title?.isEmpty == false ? title : nil, model: model, note: nil)
        } catch {
            return fallback((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
