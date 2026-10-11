import Foundation

/// Moves a finished QuickTime or MP4 file's index (the `moov` box) in front of its media
/// data, so players can start before the whole file has arrived ("fast start"), and
/// shifts the media's chunk offsets to match. The picture and sound are untouched.
///
/// AVAssetWriter can do this itself, but it rereads and rewrites the file in small
/// pieces inside `finishWriting`, which can take many minutes for a large file with no
/// progress and no way to cancel. This copies in large blocks, reports progress, and
/// stops promptly when canceled.
nonisolated enum MovieFastStart {
    enum Failure: Error, Equatable {
        case notAMovie
        /// A 32-bit chunk offset would overflow; the file is left as it was.
        case offsetsTooLarge
    }

    struct Box: Equatable {
        let type: String
        let offset: UInt64
        let size: UInt64
    }

    static let blockSize = 32 << 20

    /// Rewrites `url` with its index first. Does nothing if it already is.
    /// - Parameter progress: 0...1 as the file is copied.
    static func apply(to url: URL, isCancelled: () -> Bool = { false },
                      progress: (Double) -> Void = { _ in }) throws {
        let boxes = try topLevelBoxes(url)
        guard let moov = boxes.first(where: { $0.type == "moov" }),
              let firstMedia = boxes.first(where: { $0.type == "mdat" }) else { throw Failure.notAMovie }
        guard moov.offset > firstMedia.offset else { return }

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: moov.offset)
        guard var index = try input.read(upToCount: Int(moov.size)), index.count == Int(moov.size) else { throw Failure.notAMovie }
        // Everything from the first media box on moves down by the index's size.
        try shiftChunkOffsets(in: &index, by: moov.size)

        let end = boxes.last.map { $0.offset + $0.size } ?? moov.offset + moov.size
        let total = Double(max(end - moov.size, 1))
        var copied: UInt64 = 0
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".faststart-\(UUID().uuidString)-\(url.lastPathComponent)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw Failure.notAMovie }
        do {
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            func copy(_ range: Range<UInt64>) throws {
                try input.seek(toOffset: range.lowerBound)
                var left = range.upperBound - range.lowerBound
                while left > 0 {
                    if isCancelled() { throw CancellationError() }
                    let chunk = try autoreleasepool { try input.read(upToCount: Int(min(left, UInt64(blockSize)))) } ?? Data()
                    guard !chunk.isEmpty else { throw Failure.notAMovie }
                    try output.write(contentsOf: chunk)
                    left -= UInt64(chunk.count)
                    copied += UInt64(chunk.count)
                    progress(min(1, Double(copied) / total))
                }
            }
            try copy(0..<firstMedia.offset)
            try output.write(contentsOf: index)
            try copy(firstMedia.offset..<moov.offset)
            try copy((moov.offset + moov.size)..<end)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// The file's top-level boxes, in order.
    static func topLevelBoxes(_ url: URL) throws -> [Box] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var boxes: [Box] = []
        var offset: UInt64 = 0
        while offset + 8 <= length {
            try handle.seek(toOffset: offset)
            let header = try handle.read(upToCount: 16) ?? Data()
            guard header.count >= 8 else { break }
            var size = UInt64(bigEndian: header, at: 0, bytes: 4)
            if size == 1 {
                guard header.count >= 16 else { throw Failure.notAMovie }
                size = UInt64(bigEndian: header, at: 8, bytes: 8)
            } else if size == 0 {
                size = length - offset
            }
            guard size >= 8, offset + size <= length else { throw Failure.notAMovie }
            boxes.append(Box(type: String(decoding: header[4..<8], as: UTF8.self), offset: offset, size: size))
            offset += size
        }
        return boxes
    }

    /// Adds `shift` to every chunk offset (`stco` and `co64`) inside a `moov` box.
    static func shiftChunkOffsets(in moov: inout Data, by shift: UInt64) throws {
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "mvex"]
        func walk(_ start: Int, _ end: Int) throws {
            var offset = start
            while offset + 8 <= end {
                var size = Int(UInt64(bigEndian: moov, at: offset, bytes: 4))
                let type = String(decoding: moov[(moov.startIndex + offset + 4)..<(moov.startIndex + offset + 8)], as: UTF8.self)
                var header = 8
                if size == 1 {
                    size = Int(UInt64(bigEndian: moov, at: offset + 8, bytes: 8))
                    header = 16
                } else if size == 0 {
                    size = end - offset
                }
                guard size >= header, offset + size <= end else { throw Failure.notAMovie }
                if containers.contains(type) {
                    try walk(offset + header, offset + size)
                } else if type == "stco" || type == "co64" {
                    let width = type == "stco" ? 4 : 8
                    let count = Int(UInt64(bigEndian: moov, at: offset + header + 4, bytes: 4))
                    var entry = offset + header + 8
                    guard entry + count * width <= offset + size else { throw Failure.notAMovie }
                    for _ in 0..<count {
                        let value = UInt64(bigEndian: moov, at: entry, bytes: width) + shift
                        if width == 4 && value > UInt64(UInt32.max) { throw Failure.offsetsTooLarge }
                        moov.writeBigEndian(value, at: entry, bytes: width)
                        entry += width
                    }
                }
                offset += size
            }
        }
        try walk(8, moov.count)
    }
}

private extension UInt64 {
    nonisolated init(bigEndian data: Data, at offset: Int, bytes: Int) {
        var value: UInt64 = 0
        for i in 0..<bytes { value = value << 8 | UInt64(data[data.startIndex + offset + i]) }
        self = value
    }
}

private extension Data {
    nonisolated mutating func writeBigEndian(_ value: UInt64, at offset: Int, bytes: Int) {
        for i in 0..<bytes {
            self[startIndex + offset + i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * (bytes - 1 - i)))
        }
    }
}
