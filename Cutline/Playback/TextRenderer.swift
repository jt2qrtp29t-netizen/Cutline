import CoreGraphics
import CoreImage
import CoreText
import os

/// Draws a `TextStyle` into an image at project-pixel scale. Text is turned into
/// glyph outlines so the stroke can sit inside, centered on, or outside the edge:
/// - center: stroke of the given width centered on the outline, over the fill
/// - outside: a double-width stroke under the fill, so only its outer half shows
/// - inside: a double-width stroke clipped to the glyphs, so only its inner half shows
nonisolated enum TextRenderer {
    /// Rasterized text by style, up to 256 MB, least recently used first.
    private static let cache = LRUCache<TextStyle, CIImage>(countLimit: 256, costLimit: 256 << 20)

    /// Cached image of the text, with its origin at (0, 0); nil for empty text.
    static func image(for style: TextStyle) -> CIImage? {
        if let cached = cache[style] { return cached }
        guard let cgImage = rasterize(style) else { return nil }
        let image = CIImage(cgImage: cgImage)
        cache.set(image, for: style, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// Outline of the text, lines centered on each other, in a y-up coordinate space.
    static func path(for style: TextStyle) -> CGPath? {
        let font = CTFontCreateWithName(style.fontName as CFString, CGFloat(max(style.size, 1)), nil)
        let lines = style.string.components(separatedBy: "\n")
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading

        var linePaths: [(path: CGPath, width: CGFloat)] = []
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            let path = CGMutablePath()
            for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFontValue = attributes[kCTFontAttributeName as String]
                let runFont = runFontValue.map { $0 as! CTFont } ?? font
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                for (glyph, position) in zip(glyphs, positions) {
                    var transform = CGAffineTransform(translationX: position.x, y: position.y)
                    if let glyphPath = CTFontCreatePathForGlyph(runFont, glyph, &transform) {
                        path.addPath(glyphPath)
                    }
                }
            }
            linePaths.append((path, width))
        }

        let maxWidth = linePaths.map(\.width).max() ?? 0
        let combined = CGMutablePath()
        for (index, line) in linePaths.enumerated() {
            // First line on top; each line centered horizontally.
            let y = CGFloat(linePaths.count - 1 - index) * lineHeight
            combined.addPath(line.path, transform: CGAffineTransform(translationX: (maxWidth - line.width) / 2, y: y))
        }
        return combined.isEmpty ? nil : combined
    }

    static func rasterize(_ style: TextStyle) -> CGImage? {
        guard let path = path(for: style) else { return nil }
        let strokeWidth = style.strokeEnabled ? CGFloat(max(style.strokeWidth, 0)) : 0
        // Room for the part of the stroke that extends past the outline.
        let outset: CGFloat = switch style.strokePosition {
        case .outside: strokeWidth
        case .center: strokeWidth / 2
        case .inside: 0
        }
        let padding = ceil(outset) + 2
        let bounds = path.boundingBoxOfPath
        let width = Int(ceil(bounds.width + padding * 2)), height = Int(ceil(bounds.height + padding * 2))
        guard width > 0, height > 0, width < 16_384, height < 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.translateBy(x: padding - bounds.minX, y: padding - bounds.minY)
        context.setLineJoin(.round)
        let fill = cgColor(style.color, space), stroke = cgColor(style.strokeColor, space)

        func drawFill() {
            context.addPath(path)
            context.setFillColor(fill)
            context.fillPath()
        }
        func drawStroke(width: CGFloat) {
            context.addPath(path)
            context.setStrokeColor(stroke)
            context.setLineWidth(width)
            context.strokePath()
        }

        if strokeWidth > 0 {
            switch style.strokePosition {
            case .outside:
                drawStroke(width: strokeWidth * 2)
                drawFill()
            case .center:
                drawFill()
                drawStroke(width: strokeWidth)
            case .inside:
                drawFill()
                context.saveGState()
                context.addPath(path)
                context.clip()
                drawStroke(width: strokeWidth * 2)
                context.restoreGState()
            }
        } else {
            drawFill()
        }
        return context.makeImage()
    }

    private static func cgColor(_ color: RGBAColor, _ space: CGColorSpace) -> CGColor {
        CGColor(colorSpace: space, components: [color.red, color.green, color.blue, color.alpha])
            ?? CGColor(gray: 1, alpha: 1)
    }
}
