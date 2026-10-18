import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Cutline

@MainActor struct ThumbnailFinderTests {
    static let photoA = URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.jpg")
    static let photoB = URL(fileURLWithPath: "/System/Library/CoreServices/StageManagerOnboarding.app/Contents/Resources/StageManager_LT.ca/assets/wallpaper.jpg")

    /// A 1280×720 30 fps movie of shots, `seconds` each: images drawn from `shots`.
    static func movie(_ shots: [CIImage], seconds: Double = 2) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
        ])
        let receiver = writer.pixelReceiver(for: input)
        try writer.startOrThrow()
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        var frame = 0
        for shot in shots {
            let buffer = try Self.render(shot, context: context)
            for _ in 0..<Int(seconds * 30) {
                while try !receiver.appendImmediately(buffer, with: CMTime(value: Int64(frame), timescale: 30)) {
                    try await Task.sleep(for: .milliseconds(2))
                }
                frame += 1
            }
        }
        receiver.finish()
        await writer.finishWriting()
        return url
    }

    nonisolated static func render(_ image: CIImage, context: CIContext) throws -> ReadOnlyPixels {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        // Fill the frame (scaled to cover, centered).
        let scale = max(1280 / image.extent.width, 720 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = scaled.transformed(by: CGAffineTransform(translationX: (1280 - scaled.extent.width) / 2 - scaled.extent.minX,
                                                              y: (720 - scaled.extent.height) / 2 - scaled.extent.minY))
        context.render(placed.cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)), to: pixels)
        return ReadOnlyPixels(buffer: pixels)
    }

    static func photo(_ url: URL) throws -> CIImage { try #require(CIImage(contentsOf: url)) }
    static func flat(_ gray: Double) -> CIImage {
        CIImage(color: CIColor(red: gray, green: gray, blue: gray)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    @Test func goodDistinctFramesComeFirst() async throws {
        let a = try Self.photo(Self.photoA), b = try Self.photo(Self.photoB)
        let blurred = a.clampedToExtent().applyingGaussianBlur(sigma: 40).cropped(to: a.extent)
        // Gray, photo A, gray, blurred A, photo B, gray.
        let url = try await Self.movie([Self.flat(0.5), a, Self.flat(0.3), blurred, b, Self.flat(0.6)])
        let candidates = try await ThumbnailFinder.candidates(in: url, samples: 36, keep: 6)
        func shot(_ c: ThumbnailCandidate) -> Int { Int(c.time / 2) }
        let shots = candidates.map(shot)
        print("THUMB", candidates.map { String(format: "shot %d t=%.1f score %.2f aesth %.2f utility %d", shot($0), $0.time, $0.score, $0.aesthetics, $0.isUtility ? 1 : 0) })
        // The two photos lead; flat frames and the blurred shot rank below them.
        #expect(Set(shots.prefix(2)) == [1, 4], "\(shots)")
        let photoScores = candidates.filter { [1, 4].contains(shot($0)) }.map(\.score)
        let otherScores = candidates.filter { ![1, 4].contains(shot($0)) }.map(\.score)
        #expect((photoScores.min() ?? 0) > (otherScores.max() ?? -1), "photos beat gray and blur")
        // No near-duplicates: one frame per shot at most.
        #expect(Set(shots).count == shots.count, "\(shots)")
        #expect(candidates.allSatisfy { $0.image.width == 1280 && $0.image.height == 720 })
    }

    @Test func loudAndExcitedMomentsCount() async throws {
        // 2 s quiet, then 2 s loud.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loud-\(UUID()).wav")
        do {
            // Closed (and its header finished) at the end of this scope, before reading.
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                                                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 192_000))
            buffer.frameLength = 192_000
            for i in 0..<192_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * (i < 96_000 ? 0.05 : 0.5)) }
            try file.write(from: buffer)
        }
        let curve = try await ThumbnailFinder.loudnessCurve(of: AVURLAsset(url: url), duration: 4)
        #expect(curve[1] < 0.2 && curve[5] > 0.95, "\(curve)")

        #expect(ThumbnailFinder.isExcited("NO WAY") && ThumbnailFinder.isExcited("let's go") && ThumbnailFinder.isExcited("yes!"))
        #expect(!ThumbnailFinder.isExcited("the") && !ThumbnailFinder.isExcited("okay"))
    }
}

/// A pretend Ollama: answers by path from a table set per test.
nonisolated final class FakeOllama: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var lastChatBody: [String: Any]?
    nonisolated(unsafe) static var bodies: [String: [String: Any]] = [:]
    static func lastBody(path: String) -> [String: Any]? { bodies[path] }
    static let lock = NSLock()

    static func client() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeOllama.self]
        var client = OllamaClient()
        client.session = URLSession(configuration: configuration)
        return client
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&chunk, maxLength: chunk.count); if n <= 0 { break }; data.append(chunk, count: n) }
            stream.close()
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            Self.lock.withLock {
                Self.bodies[path] = json
                if path == "/api/chat" { Self.lastChatBody = json }
            }
        }
        guard let (status, body) = Self.lock.withLock({ Self.routes[path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func set(tags models: [(String, [String])], chat: String? = nil) {
        let tags = ["models": models.map { ["name": $0.0, "capabilities": $0.1] }]
        lock.withLock {
            routes = ["/api/tags": (200, try! JSONSerialization.data(withJSONObject: tags))]
            if let chat {
                routes["/api/chat"] = (200, try! JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": chat]]))
            }
            lastChatBody = nil
        }
    }
}

@Suite(.serialized) @MainActor struct ThumbnailPickerTests {
    /// Eight candidates, best (by Vision) first, each a small flat image.
    private func candidates() -> [ThumbnailCandidate] {
        (0..<8).map { k in
            let context = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: Double(k) / 8, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
            return ThumbnailCandidate(time: Double(k), image: context.makeImage()!, aesthetics: 0.5 - Double(k) * 0.1, isUtility: false,
                                      face: 0, loudness: 0, isExcited: false, score: 1 - Double(k) * 0.1, featurePrint: nil)
        }
    }

    @Test func withoutOllamaVisionsTopThreeAreUsed() async throws {
        let list = candidates()
        // Not running.
        var off = OllamaClient()
        off.baseURL = URL(string: "http://127.0.0.1:9")!
        let a = await ThumbnailPicker.pick(from: list, client: off)
        #expect(a.picks.map(\.candidate.time) == [0, 1, 2] && a.model == nil && a.note?.contains("isn't running") == true, "\(a.note ?? "")")
        // Running, but no models (like a moved models folder).
        FakeOllama.set(tags: [])
        let b = await ThumbnailPicker.pick(from: list, client: FakeOllama.client())
        #expect(b.model == nil && b.note?.contains("no models") == true, "\(b.note ?? "")")
        // Models, none that can see.
        FakeOllama.set(tags: [("llama3.2:latest", ["completion", "tools"])])
        let c = await ThumbnailPicker.pick(from: list, client: FakeOllama.client())
        #expect(c.note?.contains("llama3.2:latest") == true && c.picks.count == 3, "\(c.note ?? "")")
    }

    @Test func theModelsPicksAreUsedAndChecked() async throws {
        let list = candidates()
        FakeOllama.set(tags: [("llava:7b", ["completion", "vision"]), ("qwen2.5vl:7b", ["completion", "vision"])],
                       chat: #"{"picks":[{"frame":5,"reason":"Big reaction"},{"frame":2,"reason":"Boss reveal"},{"frame":7,"reason":"Clean shot"}],"title":"FINAL BOSS"}"#)
        let picks = await ThumbnailPicker.pick(from: list, context: "so this is the final boss", wantsTitle: true, client: FakeOllama.client())
        #expect(picks.picks.map(\.candidate.time) == [4, 1, 6] && picks.picks.map(\.reason) == ["Big reaction", "Boss reveal", "Clean shot"])
        #expect(picks.model == "qwen2.5vl:7b", "Qwen-VL preferred")
        #expect(picks.title == "FINAL BOSS" && picks.note == nil)
        // What went to Ollama: the 8 frames as small JPEGs, a JSON schema, the context; nothing else.
        let body = try #require(FakeOllama.lock.withLock { FakeOllama.lastChatBody })
        let message = try #require((body["messages"] as? [[String: Any]])?.first)
        #expect((message["images"] as? [String])?.count == 8 && body["format"] is [String: Any] && body["stream"] as? Bool == false)
        #expect((message["content"] as? String)?.contains("final boss") == true)
        // Enough context for the images (Ollama's default 4K isn't), and the model stays loaded.
        let options = try #require(body["options"] as? [String: Any])
        #expect((options["num_ctx"] as? Int ?? 0) >= 8 * 1_000 && body["keep_alive"] as? String == "1m", "memory back a minute after use")
        // Measured: 12 frames and the prompt took 12,577 tokens.
        #expect(OllamaClient.contextSize(images: 12, promptCharacters: 2_000) >= 12_577 + 1_000)
        // An error from Ollama is told plainly.
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"])])
        FakeOllama.lock.withLock {
            FakeOllama.routes["/api/chat"] = (400, Data(#"{"error":{"code":400,"message":"model is busy"}}"#.utf8))
        }
        let refused = await ThumbnailPicker.pick(from: list, client: FakeOllama.client())
        #expect(refused.note?.contains("model is busy") == true, "\(refused.note ?? "")")

        // Out-of-range and repeated frames are dropped; the rest comes from Vision's ranking. No title unless asked.
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"])], chat: #"{"picks":[{"frame":3,"reason":"ok"},{"frame":3,"reason":"again"},{"frame":42,"reason":"no"}],"title":"X"}"#)
        let topped = await ThumbnailPicker.pick(from: list, client: FakeOllama.client())
        #expect(topped.picks.map(\.candidate.time) == [2, 0, 1] && topped.title == nil)
        // Placeholder reasons ("…") and title get Cutline's own words instead.
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"])], chat: #"{"picks":[{"frame":2,"reason":"…"},{"frame":4,"reason":""},{"frame":6,"reason":"Big jump"}],"title":"…"}"#)
        let placeholders = await ThumbnailPicker.pick(from: list, wantsTitle: true, client: FakeOllama.client())
        #expect(placeholders.picks.map(\.reason) == [list[1].reason, list[3].reason, "Big jump"] && placeholders.title == nil)
        // Not JSON at all: Vision's top 3, and why.
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"])], chat: "I think frame three looks nice!")
        let garbled = await ThumbnailPicker.pick(from: list, client: FakeOllama.client())
        #expect(garbled.picks.map(\.candidate.time) == [0, 1, 2] && garbled.note?.contains("couldn't be used") == true)
    }

    @Test func blankFramesAreNeverOffered() async throws {
        var list = candidates()
        // Two of the eight are black (Vision rates them very low): only six frames go to the model.
        list[1] = ThumbnailCandidate(time: 1, image: list[1].image, aesthetics: -0.9, isUtility: false, face: 0, loudness: 1,
                                     isExcited: true, score: 0.9, featurePrint: nil)
        list[3] = ThumbnailCandidate(time: 3, image: list[3].image, aesthetics: 0.4, isUtility: true, emptiness: 0.95, face: 0,
                                     loudness: 0, isExcited: false, score: 0.8, featurePrint: nil)
        // A game screen Vision calls "utility" is still offered (games are screen recordings).
        list[5] = ThumbnailCandidate(time: 5, image: list[5].image, aesthetics: 0.3, isUtility: true, emptiness: 0.2, face: 0,
                                     loudness: 0, isExcited: false, score: 0.5, featurePrint: nil)
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"])], chat: #"{"picks":[{"frame":1,"reason":"a"},{"frame":2,"reason":"b"},{"frame":3,"reason":"c"}]}"#)
        let picks = await ThumbnailPicker.pick(from: list, client: FakeOllama.client())
        let sent = try #require(FakeOllama.lock.withLock { (FakeOllama.lastChatBody?["messages"] as? [[String: Any]])?.first?["images"] as? [String] })
        #expect(sent.count == 6, "the black frame and the near-empty one are left out; the utility-flagged game screen isn't")
        #expect(!picks.picks.contains { $0.candidate.time == 1 || $0.candidate.time == 3 }, "\(picks.picks.map(\.candidate.time))")
        #expect((FakeOllama.lock.withLock { FakeOllama.lastChatBody?["messages"] as? [[String: Any]] }?.first?["content"] as? String)?
            .contains("Never choose a black") == true)
        // Too few usable frames: Vision's ranking, usable ones first, no model needed.
        let few = Array(list.prefix(4))
        let fallback = await ThumbnailPicker.pick(from: few, client: FakeOllama.client())
        #expect(fallback.model == nil && fallback.picks.first?.candidate.time == 0 && fallback.picks.map(\.candidate.time).contains(2))
    }

    @Test func theBarIsSetByTheVideosOwnBestFrames() {
        func c(_ a: Double) -> ThumbnailCandidate {
            ThumbnailCandidate(time: 0, image: candidates()[0].image, aesthetics: a, isUtility: false, face: 0, loudness: 0,
                               isExcited: false, score: 0, featurePrint: nil)
        }
        // Bright, well-shot video: a blurred frame (−0.26) falls below the bar.
        #expect(ThumbnailPicker.aestheticsFloor(for: [0.76, 0.75, 0.61, -0.26].map(c)) > -0.26)
        // Dark game footage: frames around −0.3 are its normal, and stay in.
        #expect(ThumbnailPicker.aestheticsFloor(for: [0.0, -0.1, -0.2, -0.3, -0.35].map(c)) < -0.35)
        // Never lower than the fixed minimum.
        #expect(ThumbnailPicker.aestheticsFloor(for: [-0.6, -0.7, -0.8].map(c)) == ThumbnailPicker.minimumAesthetics)
    }

    @Test func theChosenModelIsUsedWhenInstalled() async throws {
        let list = candidates()
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"]), ("qwen2.5vl:3b", ["vision"]), ("llama3.2:latest", ["completion"])],
                       chat: #"{"picks":[{"frame":1,"reason":"a"},{"frame":2,"reason":"b"},{"frame":3,"reason":"c"}]}"#)
        let chosen = await ThumbnailPicker.pick(from: list, model: "qwen2.5vl:3b", client: FakeOllama.client())
        #expect(chosen.model == "qwen2.5vl:3b")
        #expect(FakeOllama.lock.withLock { FakeOllama.lastChatBody?["model"] as? String } == "qwen2.5vl:3b")
        // Removed since (or not a vision model): Automatic instead.
        #expect(await ThumbnailPicker.pick(from: list, model: "gone:1b", client: FakeOllama.client()).model == "qwen2.5vl:7b")
        #expect(await ThumbnailPicker.pick(from: list, model: "llama3.2:latest", client: FakeOllama.client()).model == "qwen2.5vl:7b")
        // Sizes come from Ollama's list (for Parameters → AI).
        FakeOllama.lock.withLock {
            FakeOllama.routes["/api/tags"] = (200, Data(#"{"models":[{"name":"qwen2.5vl:3b","capabilities":["vision"],"size":3200000000}]}"#.utf8))
        }
        #expect(try await FakeOllama.client().models() == [OllamaClient.Model(name: "qwen2.5vl:3b", capabilities: ["vision"], size: 3_200_000_000)])
    }

    @Test func closingTheStudioFreesTheModelsMemory() async throws {
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"])])
        FakeOllama.lock.withLock { FakeOllama.routes["/api/generate"] = (200, Data("{}".utf8)) }
        let client = FakeOllama.client()
        await client.unload(model: "qwen2.5vl:7b")
        let body = try #require(FakeOllama.lock.withLock { FakeOllama.lastBody(path: "/api/generate") })
        #expect(body["model"] as? String == "qwen2.5vl:7b" && body["keep_alive"] as? Int == 0)
    }

    @Test func framesGoOutSmall() throws {
        let big = try #require(CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let jpeg = try #require(OllamaClient.jpeg(big, maxSide: 512))
        let decoded = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.width == 512 && decoded.height == 288)
        #expect(try #require(OllamaClient.jpeg(big, maxSide: 448)).count < 40_000, "small enough to send a dozen")
    }

    /// With the real local Ollama, when a vision model is already loaded (e.g. just after
    /// making a thumbnail): it picks 3 of the real photos' frames. Otherwise skipped, so a
    /// test run never loads gigabytes into memory or waits minutes for a cold model.
    @Test func liveOllamaPicksThree() async throws {
        let client = OllamaClient()
        guard let model = try? await client.visionModel(), await client.loadedModels().contains(model) else {
            print("LIVE skipped: no local Ollama vision model loaded")
            return
        }
        let a = try ThumbnailFinderTests.photo(ThumbnailFinderTests.photoA), b = try ThumbnailFinderTests.photo(ThumbnailFinderTests.photoB)
        // Five different-looking shots (photos and crops of one) among blank and blurred ones.
        let plain = try ThumbnailFinderTests.photo(URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemDesktopAppearance.framework/Versions/A/Resources/DefaultBackground.jpg"))
        let e = a.extent
        let left = a.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width * 0.4, height: e.height * 0.6))
        let right = a.cropped(to: CGRect(x: e.minX + e.width * 0.6, y: e.minY + e.height * 0.4, width: e.width * 0.4, height: e.height * 0.6))
        let url = try await ThumbnailFinderTests.movie([
            a, ThumbnailFinderTests.flat(0.5), b, left, ThumbnailFinderTests.flat(0.05),
            plain, a.applyingGaussianBlur(sigma: 30).cropped(to: a.extent), right, ThumbnailFinderTests.flat(0.8),
        ], seconds: 1.5)
        let candidates = try await ThumbnailFinder.candidates(in: url, samples: 36, keep: 12)
        let clock = ContinuousClock(), start = clock.now
        let picks = await ThumbnailPicker.pick(from: candidates, context: "A calm look over the coast", wantsTitle: true)
        print("LIVE", picks.model ?? "-", picks.note ?? "", picks.title ?? "-", picks.picks.map { "\($0.candidate.time): \($0.reason)" }, clock.now - start)
        #expect(picks.model != nil, "\(picks.note ?? "")")
        #expect(picks.picks.count == 3 && Set(picks.picks.map(\.candidate.id)).count == 3)
        let floor = ThumbnailPicker.aestheticsFloor(for: candidates)
        #expect(picks.picks.allSatisfy { $0.candidate.aesthetics > floor }, "no blank or blurred frames")
    }
}

@Suite(.serialized) @MainActor struct ThumbnailStudioTests {
    private func frame(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func thumbnailsAreYouTubeSizedWithAnOptionalTitle() throws {
        let wide = try frame(width: 1920, height: 1080), tall = try frame(width: 1080, height: 1920)
        let plain = try #require(ThumbnailComposer.compose(frame: wide, title: nil, style: CaptionPreset.boldCenter.style))
        #expect(plain.width == 1280 && plain.height == 720)
        let vertical = try #require(ThumbnailComposer.compose(frame: tall, title: nil, style: CaptionPreset.boldCenter.style))
        #expect(vertical.width == 720 && vertical.height == 1280)
        // The title is drawn: bright pixels where the plain frame has none.
        let titled = try #require(ThumbnailComposer.compose(frame: wide, title: "FINAL BOSS", style: CaptionPreset.boldCenter.style))
        func bright(_ image: CGImage) throws -> Int {
            var n = 0
            for y in stride(from: 0, to: image.height, by: 6) { for x in stride(from: 0, to: image.width, by: 6) {
                let p = try TextRenderTests.pixel(image, x: x, y: y)
                if p.r > 220 && p.g > 220 && p.b > 220 { n += 1 }
            } }
            return n
        }
        #expect(try bright(plain) == 0 && bright(titled) > 50)
        // JPEG fits YouTube's 2 MB; PNG too for a plain frame.
        let jpeg = try #require(ThumbnailComposer.encode(titled, as: .jpeg))
        #expect(jpeg.count <= ThumbnailComposer.maximumBytes && jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(try #require(ThumbnailComposer.encode(titled, as: .png)).prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func fromExportToSavedThumbnail() async throws {
        let a = try ThumbnailFinderTests.photo(ThumbnailFinderTests.photoA), b = try ThumbnailFinderTests.photo(ThumbnailFinderTests.photoB)
        let plain = try ThumbnailFinderTests.photo(URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemDesktopAppearance.framework/Versions/A/Resources/DefaultBackground.jpg"))
        let e = a.extent
        let left = a.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width * 0.4, height: e.height * 0.6))
        let movie = try await ThumbnailFinderTests.movie([a, ThumbnailFinderTests.flat(0.5), b, left, plain], seconds: 1.5)
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"])],
                       chat: #"{"picks":[{"frame":2,"reason":"Rocks and waves"},{"frame":1,"reason":"Bridge at sunset"},{"frame":3,"reason":"Forest"}],"title":"COAST RUN"}"#)
        let session = ThumbnailSession(movie: movie, speech: [(2, "no way!")], client: FakeOllama.client())
        session.start()
        let deadline = ContinuousClock.now + .seconds(60)
        while session.phase != .ready, ContinuousClock.now < deadline {
            if case .failed = session.phase { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.phase == .ready, "\(session.phase)")
        #expect(session.model == "qwen2.5vl:7b" && session.picks.map(\.reason) == ["Rocks and waves", "Bridge at sunset", "Forest"])
        #expect(session.showsTitle && session.title == "COAST RUN", "the suggested title is offered")
        // The context sent included what's said.
        let content = FakeOllama.lock.withLock { (FakeOllama.lastChatBody?["messages"] as? [[String: Any]])?.first?["content"] as? String }
        #expect(content?.contains("no way!") == true)

        session.selected = 2
        session.format = .jpeg
        let saved = try #require(session.save())
        #expect(saved.lastPathComponent == movie.deletingPathExtension().lastPathComponent + "-thumbnail.jpg")
        #expect(saved.deletingLastPathComponent() == movie.deletingLastPathComponent(), "next to the movie")
        let data = try Data(contentsOf: saved)
        #expect(data.count <= ThumbnailComposer.maximumBytes)
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 1280 && image.height == 720)
        #expect(session.saveMessage?.hasPrefix("Saved") == true)
    }

    @Test func theExportsSpeechIsTimedFromItsStart() throws {
        var state = ProjectState()
        let media = MediaItem(id: UUID(), name: "talk", path: "/talk.wav", duration: Time(seconds: 30), width: 0, height: 0,
                              frameRate: 0, hasAudio: true)
        state.media = [media]
        state.transcripts[media.id] = Transcript(mediaID: media.id, locale: "en_US", words: [
            TranscriptWord(text: "before", start: 1, end: 1.4), TranscriptWord(text: "let's", start: 6, end: 6.3),
            TranscriptWord(text: "go!", start: 6.3, end: 6.8), TranscriptWord(text: "after", start: 12, end: 12.5),
        ])
        state.tracks[state.trackIndices(of: .audio)[0]].clips = [Clip(id: UUID(), mediaID: media.id, name: "t", start: .zero,
                                                                      duration: Time(seconds: 30), sourceStart: .zero)]
        let snapshot = ExportSnapshot(state: state, urls: [:], range: TimeRange(start: Time(seconds: 5), end: Time(seconds: 10)),
                                      settings: ExportSettings())
        let speech = ThumbnailSession.speech(in: snapshot)
        #expect(speech.map(\.text) == ["let's", "go!"] && abs(speech[0].time - 1) < 0.01)
    }
}
