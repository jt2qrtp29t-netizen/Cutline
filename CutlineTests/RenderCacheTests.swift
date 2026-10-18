import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Cutline

struct RenderCacheTests {
    @Test func theLeastRecentlyUsedEntriesGoFirst() {
        let cache = LRUCache<Int, String>(countLimit: 3)
        cache.set("a", for: 1); cache.set("b", for: 2); cache.set("c", for: 3)
        _ = cache[1]  // 1 is now the most recently used.
        cache.set("d", for: 4)
        #expect(cache[2] == nil, "the oldest unused entry went")
        #expect(cache[1] == "a" && cache[3] == "c" && cache[4] == "d")
        #expect(cache.count == 3)

        // Bounded by cost as well; the newest always stays.
        let sized = LRUCache<Int, Int>(countLimit: 100, costLimit: 10)
        sized.set(1, for: 1, cost: 4); sized.set(2, for: 2, cost: 4); sized.set(3, for: 3, cost: 4)
        #expect(sized[1] == nil && sized[2] == 2 && sized[3] == 3)
        sized.set(4, for: 4, cost: 50)
        #expect(sized[4] == 4 && sized.count == 1)
    }

    /// An animated grade makes a new cube every frame; a steady grade's cube must stay
    /// cached through that instead of being remade each time the cache fills.
    @Test func steadyGradesSurviveAnimatedOnes() {
        let cubes = ColorPipeline.CubeCache()
        let counter = Counter()
        let steady = ColorPipeline.CubeKey.tone(1.2, 0.9)
        func make(_ key: ColorPipeline.CubeKey) { _ = cubes.data(for: key) { counter.add(); return $0 } }
        make(steady)
        for frame in 0..<200 {
            make(.tone(Double(frame), 1))  // the animated clip
            make(steady)                    // the steady clip, drawn in the same frame
        }
        #expect(counter.value == (1 + 200) * ColorPipeline.cubeSize * ColorPipeline.cubeSize * ColorPipeline.cubeSize,
                "the steady cube was built once")
    }

    @Test func pruningKeepsTheNewestVersionAndDropsUnusedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString, other = UUID().uuidString
        func file(_ name: String, age days: Double) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let old = try file("\(id)-1000-50-proxy.mov", age: 1)
        let new = try file("\(id)-2000-60-proxy.mov", age: 1)
        let optimized = try file("\(id)-1000-50-optimized.mov", age: 1)
        let unused = try file("\(other)-1000-50-proxy.mov", age: 90)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }

        DiskCache.prune(folder, removingUnused: false)
        #expect(!exists(old) && exists(new), "a copy of an older version of the file goes")
        #expect(exists(optimized), "a different kind of copy of the same file stays")
        #expect(exists(unused), "copies made on request are kept however old")
        DiskCache.prune(folder, removingUnused: true)
        #expect(!exists(unused) && exists(new), "automatic caches drop files unused for months")
    }

    @MainActor @Test func waveformsAreKeptOnDiskForNextTime() async throws {
        let toneURL = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).wav")
        try PlaybackTests.writeTone(to: toneURL, format: kAudioFormatLinearPCM, seconds: 1)
        let tone = try await MediaImporter.makeItem(for: toneURL)
        let deadline = Date().addingTimeInterval(20)
        while WaveformCache.shared.peaks(for: tone, url: toneURL) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let peaks = try #require(WaveformCache.shared.peaks(for: tone, url: toneURL))
        #expect(!peaks.isEmpty)
        let stamp = try #require(DiskCache.stamp(for: toneURL))
        let file = DiskCache.waveforms.folder.appendingPathComponent("\(tone.id.uuidString)-\(stamp).peaks")
        let saved = try Data(contentsOf: file)
        #expect(saved.count == peaks.count * MemoryLayout<Float>.size)
        try? FileManager.default.removeItem(at: file)
    }

    @Test func thisMacReportsItsMediaHardware() {
        #expect(!HardwareInfo.gpuName.isEmpty)
        // Every Mac that runs macOS 15 decodes HEVC and encodes H.264 in hardware; Apple
        // silicon encodes HEVC too (Intel Macs vary, so it isn't required there).
        #expect(HardwareInfo.hasHardwareDecoder(for: kCMVideoCodecType_HEVC))
        #expect(HardwareInfo.hardwareEncoders.contains(kCMVideoCodecType_H264))
        #if arch(arm64)
        #expect(HardwareInfo.hardwareEncoders.contains(kCMVideoCodecType_HEVC))
        #endif
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
