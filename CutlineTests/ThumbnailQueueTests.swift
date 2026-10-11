import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct ThumbnailQueueTests {
    @Test func dragsReusePlaceholdersAndTheQueueStillDelivers() async throws {
        let ocean = try await PlaybackTests.media("Ocean")
        let cache = ThumbnailCache()
        func request(_ seconds: Double) -> ThumbnailCache.Request {
            .init(mediaID: ocean.id, url: ocean.fileURL, time: Time(seconds: seconds), tolerance: Time(seconds: 0.25))
        }
        // Mid-drag nothing is decoded: no frame yet, and none appears later.
        #expect(cache.image(for: request(1), generate: false) == nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(cache.image(for: request(1), generate: false) == nil)

        // A strip of 24 tiles, asked again on every redraw (as the timeline does): all arrive.
        let times = (0..<24).map { Double($0) * 0.5 }
        let deadline = ContinuousClock.now + .seconds(20)
        var ready = 0
        while ready < times.count && ContinuousClock.now < deadline {
            ready = times.filter { t in
                let image = cache.image(for: request(t))
                return image != nil && cache.image(for: request(t), generate: false) === image && cache.isCached(request(t))
            }.count
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ready == times.count, "\(ready) of \(times.count)")
        // During a drag, a moment not made yet shows the nearest frame already made.
        #expect(cache.image(for: request(3.3), generate: false) != nil)
        #expect(!cache.isCached(request(3.3)))
    }
}
