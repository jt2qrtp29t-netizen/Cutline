import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct FastStartTests {
    /// A minimal movie layout: ftyp, a large mdat, then a moov whose chunk offset
    /// table (stco) points at known places in the mdat.
    private func syntheticMovie(megabytes: Int) throws -> (url: URL, offsets: [UInt32], moovSize: Int) {
        let url = ExportProbe.folder().appendingPathComponent("synthetic-\(UUID()).mov")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        func box(_ type: String, _ payload: Data) -> Data {
            var data = Data()
            data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian, Array.init))
            data.append(contentsOf: Array(type.utf8))
            data.append(payload)
            return data
        }
        let ftyp = box("ftyp", Data("qt  \0\0\0\0qt  ".utf8))
        try handle.write(contentsOf: ftyp)
        // mdat: blocks of 1 MB, each starting with its block number.
        let bytes = megabytes << 20
        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: UInt32(8 + bytes).bigEndian, Array.init))
        header.append(contentsOf: Array("mdat".utf8))
        try handle.write(contentsOf: header)
        var offsets: [UInt32] = []
        for block in 0..<megabytes {
            offsets.append(UInt32(ftyp.count + 8 + block << 20))
            var chunk = Data(count: 1 << 20)
            chunk.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(block).bigEndian, Array.init))
            try handle.write(contentsOf: chunk)
        }
        var stco = Data([0, 0, 0, 0])
        stco.append(contentsOf: withUnsafeBytes(of: UInt32(offsets.count).bigEndian, Array.init))
        for offset in offsets { stco.append(contentsOf: withUnsafeBytes(of: offset.bigEndian, Array.init)) }
        let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", box("stco", stco))))))
        try handle.write(contentsOf: moov)
        return (url, offsets, moov.count)
    }

    @Test func movesTheIndexFirstAndShiftsEveryChunk() throws {
        let (url, offsets, moovSize) = try syntheticMovie(megabytes: 512)
        var reported: [Double] = []
        let start = ContinuousClock.now
        try MovieFastStart.apply(to: url, progress: { reported.append($0) })
        let seconds = (ContinuousClock.now - start) / .seconds(1)
        #expect(try MovieFastStart.topLevelBoxes(url).map(\.type) == ["ftyp", "moov", "mdat"])
        #expect(reported.last == 1 && reported == reported.sorted(), "progress rises to 100%")
        // Every chunk offset now points at its block (whose first bytes are its number).
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for block in [0, 1, 255, 511] {
            try handle.seek(toOffset: UInt64(offsets[block]) + UInt64(moovSize))
            let number = try #require(try handle.read(upToCount: 4)).reduce(0) { $0 << 8 | Int($1) }
            #expect(number == block)
        }
        // Large blocks keep it quick: half a gigabyte in well under a few seconds.
        #expect(seconds < 4, "\(seconds) s for 512 MB")
        print("FASTSTART 512 MB in \(seconds) s")
    }

    @Test func cancelingLeavesTheFileAsItWas() throws {
        let (url, _, _) = try syntheticMovie(megabytes: 256)
        let before = try MovieFastStart.topLevelBoxes(url)
        let canceled = Flag()
        #expect(throws: CancellationError.self) {
            try MovieFastStart.apply(to: url, isCancelled: { canceled.value }, progress: { _ in canceled.set() })
        }
        #expect(try MovieFastStart.topLevelBoxes(url) == before, "untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".faststart-") }
        #expect(leftovers.isEmpty)
    }
}

nonisolated private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { lock.withLock { on } }
    func set() { lock.withLock { on = true } }
}
