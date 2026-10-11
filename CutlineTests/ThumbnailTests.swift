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
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
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

    nonisolated static func render(_ image: CIImage, context: CIContext) throws -> CVReadOnlyPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        // Fill the frame (scaled to cover, centered).
        let scale = max(1280 / image.extent.width, 720 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = scaled.transformed(by: CGAffineTransform(translationX: (1280 - scaled.extent.width) / 2 - scaled.extent.minX,
                                                              y: (720 - scaled.extent.height) / 2 - scaled.extent.minY))
        context.render(placed.cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)), to: pixels)
        return CVReadOnlyPixelBuffer(unsafeBuffer: pixels)
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
        if path == "/api/chat", let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&chunk, maxLength: chunk.count); if n <= 0 { break }; data.append(chunk, count: n) }
            stream.close()
            Self.lock.withLock { Self.lastChatBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
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

        // Out-of-range and repeated frames are dropped; the rest comes from Vision's ranking. No title unless asked.
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"])], chat: #"{"picks":[{"frame":3,"reason":"ok"},{"frame":3,"reason":"again"},{"frame":42,"reason":"no"}],"title":"X"}"#)
        let topped = await ThumbnailPicker.pick(from: list, client: FakeOllama.client())
        #expect(topped.picks.map(\.candidate.time) == [2, 0, 1] && topped.title == nil)
        // Not JSON at all: Vision's top 3, and why.
        FakeOllama.set(tags: [("qwen2.5vl:7b", ["vision"])], chat: "I think frame three looks nice!")
        let garbled = await ThumbnailPicker.pick(from: list, client: FakeOllama.client())
        #expect(garbled.picks.map(\.candidate.time) == [0, 1, 2] && garbled.note?.contains("couldn't be used") == true)
    }

    @Test func framesGoOutSmall() throws {
        let big = try #require(CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let jpeg = try #require(OllamaClient.jpeg(big, maxSide: 512))
        let decoded = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.width == 512 && decoded.height == 288)
    }

    /// With the real local Ollama and a vision model installed: it picks 3 of the real photos' frames.
    @Test func liveOllamaPicksThree() async throws {
        guard (try? await OllamaClient().visionModel()) != nil else {
            print("LIVE skipped: no local Ollama vision model available")
            return
        }
        let a = try ThumbnailFinderTests.photo(ThumbnailFinderTests.photoA), b = try ThumbnailFinderTests.photo(ThumbnailFinderTests.photoB)
        let url = try await ThumbnailFinderTests.movie([a, ThumbnailFinderTests.flat(0.5), b, a.applyingGaussianBlur(sigma: 30).cropped(to: a.extent),
                                                        ThumbnailFinderTests.flat(0.2), b.applyingFilter("CIColorInvert")])
        let candidates = try await ThumbnailFinder.candidates(in: url, samples: 24, keep: 6)
        let clock = ContinuousClock(), start = clock.now
        let picks = await ThumbnailPicker.pick(from: candidates, context: "A calm look over the coast", wantsTitle: true)
        print("LIVE", picks.model ?? "-", picks.note ?? "", picks.title ?? "-", picks.picks.map { "\($0.candidate.time): \($0.reason)" }, clock.now - start)
        #expect(picks.model != nil, "\(picks.note ?? "")")
        #expect(picks.picks.count == 3 && Set(picks.picks.map(\.candidate.id)).count == 3)
    }
}
