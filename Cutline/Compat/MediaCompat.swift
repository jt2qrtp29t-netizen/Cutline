import AVFoundation
import CoreVideo

// Sequoia edition: small stand-ins for the macOS 26 media APIs the main edition uses
// (read-only pixel buffers, reader providers and writer receivers), built on the
// AVFoundation calls macOS 15 has. They keep the same shape, so the code that uses
// them reads like the main edition's.

/// A finished video frame that's only read from.
nonisolated struct ReadOnlyPixels: @unchecked Sendable {
    let buffer: CVPixelBuffer

    func withUnsafeBuffer<R>(_ body: (CVPixelBuffer) throws -> R) rethrows -> R {
        try body(buffer)
    }
}

/// One sample read from a file: a video frame or a piece of sound.
nonisolated struct ReadySample: @unchecked Sendable {
    enum Content {
        case pixelBuffer(ReadOnlyPixels)
        case other
    }

    let sampleBuffer: CMSampleBuffer

    var presentationTimeStamp: CMTime { sampleBuffer.presentationTimeStamp }

    var content: Content {
        if let pixels = sampleBuffer.imageBuffer { .pixelBuffer(ReadOnlyPixels(buffer: pixels)) } else { .other }
    }

    func withUnsafeSampleBuffer<R>(_ body: (CMSampleBuffer) throws -> R) rethrows -> R {
        try body(sampleBuffer)
    }
}

/// Hands out a reader output's samples one at a time, then nil at the end.
nonisolated final class SampleProvider: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput

    init(reader: AVAssetReader, output: AVAssetReaderOutput) {
        self.reader = reader
        self.output = output
    }

    func next() async throws -> ReadySample? {
        if let sample = output.copyNextSampleBuffer() { return ReadySample(sampleBuffer: sample) }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return nil
    }
}

/// Takes video frames for a writer input, only when it's ready for more.
nonisolated final class PixelReceiver: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let writer: AVAssetWriter

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    }

    /// False when the input isn't ready yet (try again in a moment).
    func appendImmediately(_ pixels: ReadOnlyPixels, with time: CMTime) throws -> Bool {
        guard input.isReadyForMoreMediaData else {
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            return false
        }
        guard adaptor.append(pixels.buffer, withPresentationTime: time) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return true
    }

    /// Waits (briefly, repeatedly) until the input takes the frame.
    func append(_ pixels: ReadOnlyPixels, with time: CMTime) async throws {
        while try !appendImmediately(pixels, with: time) {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func finish() { input.markAsFinished() }
}

/// Takes samples (sound) for a writer input, only when it's ready for more.
nonisolated final class SampleReceiver: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let writer: AVAssetWriter

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }

    func appendImmediately(_ sample: ReadySample) throws -> Bool {
        guard input.isReadyForMoreMediaData else {
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            return false
        }
        guard input.append(sample.sampleBuffer) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return true
    }

    func finish() { input.markAsFinished() }
}

nonisolated extension AVAssetReader {
    func sampleProvider(for output: AVAssetReaderOutput) -> SampleProvider {
        if canAdd(output), !outputs.contains(output) { add(output) }
        return SampleProvider(reader: self, output: output)
    }

    func startOrThrow() throws {
        guard startReading() else { throw error ?? CocoaError(.fileReadUnknown) }
    }
}

nonisolated extension AVAssetWriter {
    func pixelReceiver(for input: AVAssetWriterInput) -> PixelReceiver {
        if canAdd(input), !inputs.contains(input) { add(input) }
        return PixelReceiver(writer: self, input: input)
    }

    func sampleReceiver(for input: AVAssetWriterInput) -> SampleReceiver {
        if canAdd(input), !inputs.contains(input) { add(input) }
        return SampleReceiver(writer: self, input: input)
    }

    func startOrThrow() throws {
        guard startWriting() else { throw error ?? CocoaError(.fileWriteUnknown) }
    }
}
