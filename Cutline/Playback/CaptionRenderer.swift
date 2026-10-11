import CoreGraphics
import CoreImage
import CoreText

/// Captions drawn into the picture: one caption on a caption track, at a frame time.
nonisolated struct CaptionOverlay: Sendable, Equatable {
    let style: CaptionStyle
    /// The track's captions overlapping one compositor instruction, in order.
    let captions: [Caption]

    /// The caption on screen at `time`, and which of its words is being spoken.
    func showing(at time: Time) -> (caption: Caption, activeWord: Int?)? {
        guard let caption = captions.last(where: { $0.start <= time }), time < caption.end else { return nil }
        let active = style.highlightsWord ? caption.words.lastIndex { $0.start <= time } : nil
        return (caption, active)
    }
}

/// Draws captions: the words wrapped to fit the frame, centered at the style's height,
/// with fill, outline, a highlighted word and an optional box. Sizes in the style are
/// for a 1080-pixel frame and scale with the frame's shorter side (so vertical exports
/// look the same). Images are cached, so a caption is drawn once per highlighted word.
nonisolated enum CaptionRenderer {
    private struct Key: Hashable {
        let words: [String]
        let active: Int?
        let style: CaptionStyle
        let scale: Double
        let maxWidth: Double
    }

    private static let cache = LRUCache<Key, CIImage>(countLimit: 512, costLimit: 192 << 20)

    /// The caption image placed on a canvas of `renderSize` (y-up, like the compositor).
    static func image(for overlay: CaptionOverlay, at time: Time, renderSize: CGSize) -> CIImage? {
        guard let (caption, active) = overlay.showing(at: time) else { return nil }
        let scale = Double(min(renderSize.width, renderSize.height)) / 1080
        let words = caption.words.map { overlay.style.isUppercase ? $0.text.uppercased() : $0.text }
        let key = Key(words: words, active: active, style: overlay.style, scale: scale, maxWidth: Double(renderSize.width) * 0.8)
        let image: CIImage
        if let cached = cache[key] {
            image = cached
        } else {
            guard let cgImage = rasterize(key) else { return nil }
            image = CIImage(cgImage: cgImage)
            cache.set(image, for: key, cost: cgImage.bytesPerRow * cgImage.height)
        }
        // Centered horizontally; its middle at the style's height (0 = top).
        let x = (renderSize.width - image.extent.width) / 2
        let centerY = renderSize.height * (1 - CGFloat(overlay.style.position.clamped(to: 0...1)))
        let y = min(max(centerY - image.extent.height / 2, 0), max(renderSize.height - image.extent.height, 0))
        return image.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
    }

    /// One word's glyph outline at the baseline origin, and its advance.
    private static func word(_ text: String, font: CTFont) -> (path: CGPath, width: CGFloat) {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                var transform = CGAffineTransform(translationX: position.x, y: position.y)
                if let glyphPath = CTFontCreatePathForGlyph(runFont, glyph, &transform) { path.addPath(glyphPath) }
            }
        }
        return (path, width)
    }

    private static func rasterize(_ key: Key) -> CGImage? {
        let style = key.style
        let size = CGFloat(max(style.size * key.scale, 4))
        let font = CTFontCreateWithName(style.fontName as CFString, size, nil)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = (ascent + descent) * 1.12
        let space = word(" ", font: font).width
        let measured = key.words.map { word($0, font: font) }

        // Greedy wrapping to the width.
        var lines: [[Int]] = [[]]
        var lineWidth: CGFloat = 0
        for (k, w) in measured.enumerated() {
            let added = lines[lines.count - 1].isEmpty ? w.width : lineWidth + space + w.width
            if !lines[lines.count - 1].isEmpty && added > CGFloat(key.maxWidth) {
                lines.append([k])
                lineWidth = w.width
            } else {
                lines[lines.count - 1].append(k)
                lineWidth = added
            }
        }
        let widths = lines.map { line in line.map { measured[$0].width }.reduce(0, +) + space * CGFloat(max(line.count - 1, 0)) }
        let textWidth = widths.max() ?? 0
        let textHeight = lineHeight * CGFloat(lines.count)

        let stroke = CGFloat(max(style.strokeWidth * key.scale, 0))
        let boxPadding: CGFloat = style.showsBox ? size * 0.35 : 0
        let padding = ceil(stroke) + boxPadding + 2
        let width = Int(ceil(textWidth + padding * 2)), height = Int(ceil(textHeight + padding * 2))
        guard textWidth > 0, width > 0, height > 0, width < 16_384, height < 16_384,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        func color(_ c: RGBAColor) -> CGColor {
            CGColor(colorSpace: colorSpace, components: [c.red, c.green, c.blue, c.alpha]) ?? CGColor(gray: 1, alpha: 1)
        }

        if style.showsBox {
            let box = CGRect(x: padding - boxPadding, y: padding - boxPadding,
                             width: textWidth + boxPadding * 2, height: textHeight + boxPadding * 2)
            context.addPath(CGPath(roundedRect: box, cornerWidth: size * 0.25, cornerHeight: size * 0.25, transform: nil))
            context.setFillColor(color(style.boxColor))
            context.fillPath()
        }

        // Each word's outline in place (first line on top, each line centered).
        var placed: [(path: CGPath, index: Int)] = []
        for (row, line) in lines.enumerated() {
            var x = padding + (textWidth - widths[row]) / 2
            let baseline = padding + CGFloat(lines.count - 1 - row) * lineHeight + descent + (lineHeight - ascent - descent) / 2
            for k in line {
                var transform = CGAffineTransform(translationX: x, y: baseline)
                if let path = measured[k].path.copy(using: &transform) { placed.append((path, k)) }
                x += measured[k].width + space
            }
        }
        context.setLineJoin(.round)
        if stroke > 0 {
            // Outside outline: a double-width stroke under the fill.
            context.setStrokeColor(color(style.strokeColor))
            context.setLineWidth(stroke * 2)
            for word in placed { context.addPath(word.path) }
            context.strokePath()
        }
        for word in placed {
            context.addPath(word.path)
            context.setFillColor(color(word.index == key.active ? style.highlightColor : style.color))
            context.fillPath()
        }
        return context.makeImage()
    }
}
