import CoreGraphics
import Foundation
import Testing
@testable import Cutline

struct TextRenderTests {
    static func style(_ adjust: (inout TextStyle) -> Void = { _ in }) -> TextStyle {
        var style = TextStyle()
        style.string = "I"
        style.size = 300
        style.strokeColor = RGBAColor(red: 1, green: 0, blue: 0)
        style.strokeWidth = 10
        adjust(&style)
        return style
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int, a: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3]))
    }

    /// First opaque pixel from the left along the middle row.
    static func edgeColor(_ image: CGImage) throws -> (r: Int, g: Int, b: Int, a: Int) {
        for x in 0..<image.width {
            let p = try pixel(image, x: x, y: image.height / 2)
            if p.a > 200 { return p }
        }
        return (0, 0, 0, 0)
    }

    @Test func strokeSitsInsideOnOrOutsideTheOutline() throws {
        let plain = try #require(TextRenderer.rasterize(Self.style()))
        let outside = try #require(TextRenderer.rasterize(Self.style { $0.strokeEnabled = true; $0.strokePosition = .outside }))
        let center = try #require(TextRenderer.rasterize(Self.style { $0.strokeEnabled = true; $0.strokePosition = .center }))
        let inside = try #require(TextRenderer.rasterize(Self.style { $0.strokeEnabled = true; $0.strokePosition = .inside }))

        // Outside adds the full width on each side, center half of it, inside nothing.
        #expect(abs(outside.width - plain.width - 20) <= 2, "outside \(outside.width) vs \(plain.width)")
        #expect(abs(center.width - plain.width - 10) <= 2, "center \(center.width) vs \(plain.width)")
        #expect(abs(inside.width - plain.width) <= 1, "inside \(inside.width) vs \(plain.width)")

        for image in [outside, center, inside] {
            let edge = try Self.edgeColor(image)
            #expect(edge.r > 200 && edge.g < 60, "edge is the stroke color: \(edge)")
            let middle = try Self.pixel(image, x: image.width / 2, y: image.height / 2)
            #expect(middle.g > 200, "middle stays the fill: \(middle)")
        }
        #expect(try Self.edgeColor(plain).g > 200, "without stroke the edge is the fill")
    }

    @Test func linesStackAndEmptyTextDrawsNothing() throws {
        let one = try #require(TextRenderer.path(for: Self.style { $0.string = "Hello" }))
        let two = try #require(TextRenderer.path(for: Self.style { $0.string = "Hello\nHi" }))
        #expect(two.boundingBoxOfPath.height > one.boundingBoxOfPath.height * 1.8)
        #expect(TextRenderer.path(for: Self.style { $0.string = "" }) == nil)
    }
}
