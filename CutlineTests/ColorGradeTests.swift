import CoreImage
import Foundation
import Testing
@testable import Cutline

struct ColorGradeTests {
    // MARK: Rendering helpers

    private let context = CIContext(options: [.cacheIntermediates: false])

    /// A flat color given in encoded Rec.709 values.
    private func flat(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: ColorPipeline.gradingSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    /// The image's color in encoded Rec.709, 0...255 per channel.
    private func pixel(_ image: CIImage) -> SIMD3<Int> {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 1, y: 1, width: 1, height: 1),
                       format: .RGBA8, colorSpace: ColorPipeline.gradingSpace)
        return SIMD3(Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func render(_ grade: ColorGrade, _ r: Double, _ g: Double, _ b: Double, lut: CubeLUT? = nil) -> SIMD3<Int> {
        pixel(ColorPipeline.apply(grade, to: flat(r, g, b), lut: lut))
    }

    private func close(_ a: SIMD3<Int>, _ b: SIMD3<Int>, within tolerance: Int = 1) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.z - b.z) <= tolerance
    }

    private let samples: [SIMD3<Double>] = [
        SIMD3(0.05, 0.05, 0.05), SIMD3(0.2, 0.5, 0.8), SIMD3(0.5, 0.5, 0.5), SIMD3(0.9, 0.3, 0.1), SIMD3(0.95, 0.95, 0.95),
    ]

    // MARK: Identity

    @Test func identityGradeLeavesPixelsUnchanged() {
        // Neutral, plus "neutral but not default": diagonal curve points and a flat hue curve.
        var identity = ColorGrade()
        identity.curves.master = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)])
        identity.hueSaturation.points = [CurvePoint(x: 0.3, y: 0.5)]
        for grade in [ColorGrade.neutral, identity] {
            for c in samples {
                let original = pixel(flat(c.x, c.y, c.z))
                #expect(close(render(grade, c.x, c.y, c.z), original), "\(c)")
            }
        }
    }

    @Test func zeroOffsetIsIdentity() {
        var grade = ColorGrade()
        grade.offset = ColorWheel(x: 0, y: 0, master: 0)
        for c in samples {
            #expect(ColorPipeline.primaries(c, grade) == c)
            #expect(render(grade, c.x, c.y, c.z) == pixel(flat(c.x, c.y, c.z)))
        }
    }

    @Test func offsetShiftsEveryValueEqually() {
        var grade = ColorGrade()
        grade.offset.master = 0.2   // +0.1 on every channel
        for c in samples {
            let out = ColorPipeline.primaries(c, grade)
            let shift = out - c
            #expect(abs(shift.x - 0.1) < 1e-12 && abs(shift.y - 0.1) < 1e-12 && abs(shift.z - 0.1) < 1e-12)
        }
        // Rendered: dark, mid and light grays all move up by the same amount.
        let shifts = [0.1, 0.4, 0.7].map { v -> Int in render(grade, v, v, v).x - pixel(flat(v, v, v)).x }
        #expect(shifts.allSatisfy { abs($0 - 26) <= 1 }, "\(shifts)")
        // The color part shifts channels by fixed amounts too, independent of brightness.
        var tinted = ColorGrade()
        tinted.offset = ColorWheel(x: 0, y: 0.4, master: 0)
        let a = ColorPipeline.primaries(SIMD3(0.2, 0.2, 0.2), tinted) - SIMD3(0.2, 0.2, 0.2)
        let b = ColorPipeline.primaries(SIMD3(0.7, 0.7, 0.7), tinted) - SIMD3(0.7, 0.7, 0.7)
        #expect(abs(a.x - b.x) < 1e-12 && abs(a.y - b.y) < 1e-12 && abs(a.z - b.z) < 1e-12)
        #expect(a.x > 0 && a.y < 0, "toward red")
    }

    @Test func largeNegativeOffsetIsNotClampedMidPipeline() {
        // Offset far below black, then gain back up: values survive until the final clamp.
        var grade = ColorGrade()
        grade.offset.master = -0.4   // -0.2
        grade.lift.master = 0.4      // +0.2 toward white, scaled by (1 - v)
        let out = ColorPipeline.primaries(SIMD3(0.1, 0.1, 0.1), grade)
        // 0.1 - 0.2 = -0.1, then -0.1 + 0.2 * 1.1 = 0.12: the negative value was kept.
        #expect(abs(out.x - 0.12) < 1e-12)
    }

    // MARK: Order

    @Test func gradeOrderIsFixed() {
        // Offset before gain: (0.1 + 0.1) × 2, not 0.1 × 2 + 0.1.
        var grade = ColorGrade()
        grade.offset.master = 0.2
        grade.gain.master = 1
        #expect(abs(ColorPipeline.primaries(SIMD3(repeating: 0.1), grade).x - 0.4) < 1e-12)

        // White balance before offset: the warm gain doesn't scale the offset.
        var warm = ColorGrade()
        warm.temperature = 1
        warm.offset.master = 0.2
        #expect(abs(ColorPipeline.primaries(SIMD3(repeating: 0.5), warm).x - (0.5 * 1.3 + 0.1)) < 1e-12)

        // Lift before gain, gain before gamma.
        var lgg = ColorGrade()
        lgg.lift.master = 0.2      // +0.1 × (1 - v)
        lgg.gain.master = 0.5      // × 1.5
        lgg.gamma.master = 1       // ^ 0.5
        let expected = pow((0.4 + 0.1 * 0.6) * 1.5, 0.5)
        #expect(abs(ColorPipeline.primaries(SIMD3(repeating: 0.4), lgg).x - expected) < 1e-12)

        // Curves before the LUT: an inverting LUT after a curve that doubles values.
        var curved = ColorGrade()
        curved.curves.master = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 1)])
        let invert = try! CubeLUT.parse("LUT_3D_SIZE 2\n1 1 1\n0 1 1\n1 0 1\n0 0 1\n1 1 0\n0 1 0\n1 0 0\n0 0 0\n")
        let out = ColorPipeline.secondaries(SIMD3(repeating: 0.25), curved, lut: invert)
        #expect(abs(out.x - 0.5) < 1e-9, "curve to 0.5 first, then inverted to 0.5: \(out)")
        let out2 = ColorPipeline.secondaries(SIMD3(repeating: 0.1), curved, lut: invert)
        #expect(abs(out2.x - 0.8) < 1e-9, "0.1 → curve 0.2 → LUT 0.8 (not 0.9 → 1.8): \(out2)")
    }

    @Test func warmerTemperatureRaisesRedAndLowersBlue() {
        var grade = ColorGrade()
        grade.temperature = 0.5
        let out = render(grade, 0.5, 0.5, 0.5)
        #expect(out.x > out.y && out.z < out.y, "\(out)")
    }

    @Test func wheelPuckChangesColorButNotBrightness() {
        let wheel = ColorWheel(x: 0.3, y: -0.6, master: 0)
        let luma = (wheel.chroma * ColorPipeline.lumaWeights).sum()
        #expect(abs(luma) < 1e-4)
    }

    // MARK: Curves

    @Test func curvesPassThroughTheirPointsWithoutOvershooting() {
        let curve = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.6),
                                       CurvePoint(x: 0.5, y: 0.65), CurvePoint(x: 1, y: 1)])
        for p in curve.points { #expect(abs(curve.value(at: p.x) - p.y) < 1e-12) }
        // Monotone points give a monotone curve: no dips or overshoot between them.
        var previous = -Double.infinity
        for i in 0...200 {
            let y = curve.value(at: Double(i) / 200)
            #expect(y >= previous - 1e-12)
            #expect(y <= 1 + 1e-12)
            previous = y
        }
        #expect(ToneCurve.identity.value(at: 0.37) == 0.37)
        // Outside the points the curve continues with slope 1 instead of flattening.
        #expect(abs(ToneCurve.identity.value(at: 1.2) - 1.2) < 1e-12)
        #expect(abs(ToneCurve.identity.value(at: -0.1) + 0.1) < 1e-12)
    }

    @Test func hueCurveScalesSaturationAndWraps() {
        var curve = HueCurve()
        curve.points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1.0 / 3, y: 0.5), CurvePoint(x: 2.0 / 3, y: 0.5)]
        #expect(curve.saturationScale(atHue: 0) == 0, "reds desaturated")
        #expect(abs(curve.saturationScale(atHue: 1.0 / 3) - 1) < 1e-9, "greens unchanged")
        #expect(abs(curve.saturationScale(atHue: 0.9999) - curve.saturationScale(atHue: 0.0001)) < 0.01, "wraps")
        // A desaturated red renders gray.
        var grade = ColorGrade()
        grade.hueSaturation = curve
        let out = render(grade, 0.8, 0.2, 0.2)
        #expect(abs(out.x - out.y) <= 2 && abs(out.y - out.z) <= 2, "\(out)")
    }

    // MARK: LUTs

    @Test func cubeFilesParse() throws {
        let text = """
        # Comment
        TITLE "Warm"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try CubeLUT.parse(text)
        #expect(lut.title == "Warm" && lut.size == 2 && lut.table.count == 8)
        let mid = lut.sample(SIMD3(0.25, 0.5, 0.75))
        #expect(abs(mid.x - 0.25) < 1e-6 && abs(mid.y - 0.5) < 1e-6 && abs(mid.z - 0.75) < 1e-6, "identity LUT")
    }

    @Test func invalidCubeFilesGiveClearErrors() {
        #expect(throws: CubeLUT.ParseError.empty) { try CubeLUT.parse("  \n# nothing\n") }
        #expect(throws: CubeLUT.ParseError.missingSize) { try CubeLUT.parse("0 0 0\n1 1 1\n") }
        #expect(throws: CubeLUT.ParseError.oneDimensional) { try CubeLUT.parse("LUT_1D_SIZE 4\n0 0 0\n") }
        #expect(throws: CubeLUT.ParseError.wrongEntryCount(expected: 8, found: 2)) {
            try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 1 1\n")
        }
        #expect(throws: CubeLUT.ParseError.badLine(number: 2, text: "0 zero 0")) {
            try CubeLUT.parse("LUT_3D_SIZE 2\n0 zero 0\n")
        }
        #expect(throws: CubeLUT.ParseError.unsupportedSize(1)) { try CubeLUT.parse("LUT_3D_SIZE 1\n0 0 0\n") }
        // Not a text file at all.
        let binary = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cube")
        try? Data([0xFF, 0x00, 0xFE, 0x12]).write(to: binary)
        #expect(throws: (any Error).self) { try CubeLUT.load(from: binary) }
    }

    @Test func missingLUTFallsBackToNoLUT() {
        var grade = ColorGrade()
        grade.lut = LUTReference(name: "Gone", path: "/nonexistent/\(UUID()).cube")
        #expect(LUTLibrary.shared.lut(for: grade.lut) == nil)
        #expect(!LUTLibrary.shared.isAvailable(grade.lut!))
        #expect(render(grade, 0.3, 0.5, 0.7) == pixel(flat(0.3, 0.5, 0.7)), "renders as if there were no LUT")
    }

    // MARK: Old projects, saving, blading

    @Test func oldProjectsLoadAndRenderIdentically() throws {
        let json = #"{"exposure":0.5,"brightness":0.05,"contrast":1.2,"saturation":0.7}"#
        let grade = try JSONDecoder().decode(ColorGrade.self, from: Data(json.utf8))
        #expect(grade.exposure == 0.5 && grade.contrast == 1.2 && grade.offset.isNeutral && grade.lut == nil)

        // The previous renderer: exposure, then color controls, nothing else.
        let source = flat(0.3, 0.5, 0.2)
        let old = source.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.5])
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.05, kCIInputContrastKey: 1.2,
                                                            kCIInputSaturationKey: 0.7])
        #expect(pixel(ColorPipeline.apply(grade, to: source, lut: nil)) == pixel(old))
    }

    @Test func gradesRoundTrip() throws {
        var state = ProjectState()
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        clip.color.offset = ColorWheel(x: 0.1, y: -0.2, master: -0.3)
        clip.color.gamma = ColorWheel(x: -0.4, y: 0.2, master: 0.1)
        clip.color.curves.red = ToneCurve(points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 0.6, y: 0.4), CurvePoint(x: 1, y: 1)])
        clip.color.hueSaturation.points = [CurvePoint(x: 0.2, y: 0.8)]
        clip.color.lut = LUTReference(name: "Film", path: "/Users/someone/LUTs/Film.cube", bookmark: Data([1, 2, 3]))
        clip.color.lutIntensity = 0.6
        clip.color.temperature = 0.3
        clip.animation.setKeyframe(.offsetMaster, at: .zero, value: 0)
        clip.animation.setKeyframe(.offsetMaster, at: Time(seconds: 2), value: 0.5)
        state.tracks[0].clips = [clip]
        let decoded = try ProjectState.decode(state.encoded())
        #expect(decoded == state)
        #expect(decoded.tracks[0].clips[0].color.lut?.path == "/Users/someone/LUTs/Film.cube")
    }

    @Test func bladingAKeyframedGradeHasNoJump() {
        var state = ProjectState()
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        clip.color.curves.master = ToneCurve(points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)])
        clip.animation.setKeyframe(.liftMaster, at: .zero, value: -0.5)
        clip.animation.setKeyframe(.liftMaster, at: Time(seconds: 4), value: 0.5)
        clip.animation.setKeyframe(.offsetX, at: Time(seconds: 1), value: 0.4)
        clip.animation.setKeyframe(.offsetX, at: Time(seconds: 3), value: -0.4)
        state.tracks[0].clips = [clip]
        let before = (0...40).map { clip.grade(at: Time(seconds: Double($0) / 10)) }

        let created = TimelineEditing.blade(at: Time(seconds: 2), clips: [clip.id], in: &state)
        let left = state.clip(clip.id)!, right = state.clip(created[0])!
        #expect(left.color.curves == clip.color.curves && right.color.curves == clip.color.curves, "both halves keep the grade")
        for (i, expected) in before.enumerated() {
            let t = Time(seconds: Double(i) / 10)
            let half = t < Time(seconds: 2) ? left : right
            let g = half.grade(at: t)
            #expect(abs(g.lift.master - expected.lift.master) < 1e-9 && abs(g.offset.x - expected.offset.x) < 1e-9, "at \(t.seconds)")
        }
        // Right at the cut both halves agree.
        let cut = Time(seconds: 2)
        #expect(abs(left.grade(at: cut).lift.master - right.grade(at: cut).lift.master) < 1e-9)
    }

    @MainActor @Test func aWheelDragIsOneUndoStep() {
        var state = ProjectState()
        let clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo

        undo.beginUndoGrouping()
        editor.store.beginLiveEdit()
        for step in 1...10 {
            editor.setGradeValues([.gainX: Double(step) * 0.03, .gainY: Double(step) * -0.02], of: clip.id,
                                  actionName: "Change Gain")
        }
        editor.store.commitLiveEdit("Change Gain")
        undo.endUndoGrouping()
        #expect(abs(editor.state.clip(clip.id)!.color.gain.x - 0.3) < 1e-12)
        #expect(abs(editor.state.clip(clip.id)!.color.gain.y + 0.2) < 1e-12)
        undo.undo()
        #expect(editor.state.clip(clip.id)!.color.gain == .neutral, "one undo puts the whole drag back")
        #expect(!undo.canUndo)
    }

    @Test func colorPropertiesAreKeyframableAndSeparateFromMotion() {
        #expect(AnimatableProperty.grade.count == 21)
        #expect(Set(AnimatableProperty.motion).isDisjoint(with: AnimatableProperty.grade))
        for property in [AnimatableProperty.offsetX, .offsetY, .offsetMaster, .liftMaster, .gammaMaster, .gainMaster] {
            var clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
            clip.animation.setKeyframe(property, at: .zero, value: 0)
            clip.animation.setKeyframe(property, at: Time(seconds: 2), value: 0.8)
            let g = clip.grade(at: Time(seconds: 1))
            var expected = clip
            expected[keyPath: property.keyPath] = 0.4
            #expect(g == expected.color, "\(property)")
        }
    }
}
