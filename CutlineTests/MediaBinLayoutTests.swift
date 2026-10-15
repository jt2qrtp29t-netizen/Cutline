import AppKit
import SwiftUI
import Testing
@testable import Cutline

@MainActor struct MediaBinLayoutTests {
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// Posters of any shape stay inside the panel's width (vertical and ultrawide videos
    /// used to push the card past the window's edge).
    @Test func postersOfAnyShapeStayInTheirBox() throws {
        for (w, h) in [(1080, 1920), (1440, 1080), (3440, 1080), (1920, 1080)] {
            let poster = PosterFrame(image: try image(width: w, height: h)).aspectRatio(16 / 9, contentMode: .fit)
            let size = NSHostingController(rootView: poster).sizeThatFits(in: CGSize(width: 260, height: 10_000))
            #expect(abs(size.width - 260) < 0.5 && abs(size.height - 260 * 9 / 16) < 0.5, "\(w)×\(h): \(size)")
        }
    }
}

@MainActor struct ThumbnailCacheEvictionTests {
    private func frame() -> CGImage {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// Frames on screen (asked for on every redraw) are never the ones dropped when the
    /// cache is full: dropping them made the timeline and media posters flicker.
    @Test func framesOnScreenStayWhenTheCacheIsFull() {
        let cache = ThumbnailCache(costLimit: 40_000 * 20)   // room for 20 frames
        let media = UUID(), url = URL(fileURLWithPath: "/clip.mov")
        func request(_ second: Int) -> ThumbnailCache.Request { .init(mediaID: media, url: url, time: Time(seconds: Double(second))) }
        let onScreen = (0..<8).map(request)
        for r in onScreen { cache.insert(frame(), for: r) }
        // Scrolling elsewhere fills the cache many times over, while the visible ones redraw.
        for second in 100..<300 {
            cache.insert(frame(), for: request(second))
            for r in onScreen { _ = cache.image(for: r, generate: false) }
        }
        #expect(onScreen.allSatisfy(cache.isCached), "nothing visible was dropped")
        #expect(!cache.isCached(request(100)), "the oldest unseen ones were")

        // Short of memory: shrinks, keeping the most recently shown.
        cache.trim(to: 40_000 * 8)
        #expect(onScreen.allSatisfy(cache.isCached))
        #expect(!cache.isCached(request(299)))

        // A stand-in is always a frame that's still there (never a dropped one).
        #expect(cache.image(for: request(150), generate: false) != nil)
    }
}
