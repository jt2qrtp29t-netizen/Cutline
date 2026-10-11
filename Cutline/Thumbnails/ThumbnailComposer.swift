import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes the final thumbnail: the frame filling the picture, with an optional title drawn
/// like a caption, encoded as PNG or JPEG within YouTube's limit.
nonisolated enum ThumbnailComposer {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case png, jpeg
        var id: String { rawValue }
        var fileExtension: String { self == .png ? "png" : "jpg" }
        var title: String { self == .png ? "PNG" : "JPEG" }
    }

    /// YouTube's thumbnail limit.
    static let maximumBytes = 2_000_000

    /// 1280×720 for landscape video, 720×1280 for vertical.
    static func size(for frame: CGImage) -> CGSize {
        frame.height > frame.width ? CGSize(width: 720, height: 1280) : CGSize(width: 1280, height: 720)
    }

    /// Titles are drawn bigger than captions: this many times the style's size.
    static let titleScale = 2.2

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func compose(frame: CGImage, title: String?, style: CaptionStyle) -> CGImage? {
        let size = size(for: frame)
        let source = CIImage(cgImage: frame)
        // Cover the picture (scaled up and centered).
        let scale = max(size.width / source.extent.width, size.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var image = scaled.transformed(by: CGAffineTransform(translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                             y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY))
        let canvas = CGRect(origin: .zero, size: size)
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            var titleStyle = style
            titleStyle.size = style.size * titleScale
            titleStyle.highlightsWord = false
            let words = title.split(whereSeparator: \.isWhitespace).map {
                CaptionWord(wordID: UUID(), mediaID: UUID(), text: String($0), start: .zero, end: Time(seconds: 1), startsCaption: false)
            }
            let overlay = CaptionOverlay(style: titleStyle, captions: [Caption(words: words, start: .zero, end: Time(seconds: 1))])
            if let text = CaptionRenderer.image(for: overlay, at: .zero, renderSize: size) {
                image = text.composited(over: image)
            }
        }
        return context.createCGImage(image.cropped(to: canvas), from: canvas, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The image as a file. JPEG quality steps down until it fits `maximumBytes`; a PNG is as it is.
    static func encode(_ image: CGImage, as format: Format) -> Data? {
        func encoded(quality: Double) -> Data? {
            let data = NSMutableData()
            let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
            guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
            let options: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
        guard format == .jpeg else { return encoded(quality: 1) }
        var quality = 0.92
        while quality > 0.3 {
            if let data = encoded(quality: quality), data.count <= maximumBytes { return data }
            quality -= 0.08
        }
        return encoded(quality: 0.3)
    }
}
