import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Cutline

struct LabsTests {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let canvas = CGRect(x: 0, y: 0, width: 320, height: 180)

    private func pixel(_ image: CIImage, x: CGFloat = 160, y: CGFloat = 90) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes.prefix(3).map(Int.init)
    }

    /// Left half red, right half blue.
    private var testPicture: CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 180))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: canvas))
    }

    @Test func registryIsWellFormed() {
        let all = ExperimentRegistry.builtIn
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.filter { $0.kind == .generator }.map(\.id) == ["solid", "gradient", "noise", "bars"])
        #expect(Set(all.filter { $0.kind == .effect }.map(\.id)) == ["rgbSplit", "waveWarp", "customShader"])
        for experiment in all {
            #expect(Set(experiment.parameters.map(\.id)).count == experiment.parameters.count)
            for parameter in experiment.parameters { #expect(parameter.range.contains(parameter.defaultValue)) }
        }
    }

    @Test func everyStarterExperimentRenders() throws {
        for experiment in ExperimentRegistry.builtIn {
            var effect = LabEffect(experimentID: experiment.id, values: experiment.defaultValues())
            effect.source = experiment.defaultSource
            let output: CIImage?
            if experiment.kind == .generator {
                output = LabRenderer.generate(effect, canvas: canvas, time: 0.5)
            } else {
                output = LabRenderer.apply([effect], to: testPicture, canvas: canvas, time: 0.5)
            }
            #expect(output != nil && LabStatus.currentError(effect.id) == nil, "\(experiment.id): \(LabStatus.currentError(effect.id) ?? "")")
            if let output { _ = pixel(output) }   // actually runs on the GPU
            #expect(LabStatus.currentError(effect.id) == nil)
        }
    }

    @Test func generatorsDrawWhatTheirParametersSay() {
        let red = LabEffect(experimentID: "solid", values: ["hue": 0, "saturation": 1, "brightness": 1])
        let p = pixel(LabRenderer.generate(red, canvas: canvas, time: 0)!)
        #expect(p[0] > 240 && p[1] < 15 && p[2] < 15, "\(p)")
        let bars = LabRenderer.generate(LabEffect(experimentID: "bars", values: ["level": 0.75]), canvas: canvas, time: 0)!
        let first = pixel(bars, x: 10), last = pixel(bars, x: 310)
        #expect(abs(first[0] - first[2]) < 4 && first[0] > 150, "gray bar first: \(first)")
        #expect(last[2] > 150 && last[0] < 20, "blue bar last: \(last)")
    }

    @Test func rgbSplitPullsChannelsApart() {
        let effect = LabEffect(experimentID: "rgbSplit", values: ["amount": 20, "angle": 0, "glitch": 0, "speed": 0])
        let out = LabRenderer.apply([effect], to: testPicture, canvas: canvas, time: 0)
        // Just right of the red/blue edge, red has been pushed over the blue: magenta.
        let p = pixel(out, x: 170)
        #expect(p[0] > 200 && p[2] > 200, "\(p)")
        #expect(pixel(out, x: 80) == pixel(testPicture, x: 80) || pixel(out, x: 80)[0] > 200)
    }

    @Test func aFailingExperimentFallsBackToTheUnchangedPicture() {
        ExperimentRegistry.register(Experiment(id: "test.fail", name: "Always Fails", summary: "", kind: .effect,
                                               symbolName: "xmark") { _ in
            throw ExperimentError.message("Deliberate failure.")
        })
        let failing = LabEffect(experimentID: "test.fail")
        let out = LabRenderer.apply([failing], to: testPicture, canvas: canvas, time: 0)
        #expect(pixel(out, x: 40) == pixel(testPicture, x: 40) && pixel(out, x: 280) == pixel(testPicture, x: 280))
        #expect(LabStatus.currentError(failing.id) == "Deliberate failure.")

        // A bad parameter value and an unknown experiment fail the same safe way.
        var nan = LabEffect(experimentID: "rgbSplit")
        nan.keyframes["amount"] = [Keyframe(time: .zero, value: .nan)]
        #expect(pixel(LabRenderer.apply([nan], to: testPicture, canvas: canvas, time: 0), x: 170) == pixel(testPicture, x: 170))
        #expect(LabStatus.currentError(nan.id) != nil)
        let unknown = LabEffect(experimentID: "from.the.future")
        #expect(LabRenderer.generate(unknown, canvas: canvas, time: 0) == nil)
        #expect(LabStatus.currentError(unknown.id) != nil)

        // Later effects still run after a failing one.
        let split = LabEffect(experimentID: "rgbSplit", values: ["amount": 20, "glitch": 0])
        let both = LabRenderer.apply([failing, split], to: testPicture, canvas: canvas, time: 0)
        #expect(pixel(both, x: 170)[0] > 200)
    }

    @Test func aShaderThatDoesntCompileFallsBackWithTheCompilerMessage() {
        var shader = LabEffect(experimentID: "customShader")
        shader.source = """
        #include <CoreImage/CoreImage.h>
        extern "C" float4 shade(coreimage::sample_t color, float a, float b, float c, float time) [[stitchable]] {
            return color.rgba + undefinedThing;
        }
        """
        let out = LabRenderer.apply([shader], to: testPicture, canvas: canvas, time: 0)
        #expect(pixel(out, x: 40) == pixel(testPicture, x: 40))
        let message = LabStatus.currentError(shader.id) ?? ""
        #expect(message.contains("didn’t compile") && message.contains("undefinedThing"), "\(message)")
        #expect(!message.contains("program_source"))

        // Fixing the code makes it work again.
        shader.source = LabShaders.customDefault
        _ = pixel(LabRenderer.apply([shader], to: testPicture, canvas: canvas, time: 0))
        #expect(LabStatus.currentError(shader.id) == nil)
    }

    @Test func labParametersAreKeyframedAndSplitWhenBladed() {
        var state = ProjectState()
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        var effect = LabEffect(experimentID: "rgbSplit")
        effect.setKeyframe("amount", at: .zero, value: 0)
        effect.setKeyframe("amount", at: Time(seconds: 4), value: 40)
        clip.labs = [effect]
        state.tracks[0].clips = [clip]
        #expect(effect.value(of: "amount", default: 0, atOffset: Time(seconds: 1)) == 10)

        let created = TimelineEditing.blade(at: Time(seconds: 2), clips: [clip.id], in: &state)
        let left = state.clip(clip.id)!.labs[0], right = state.clip(created[0])!.labs[0]
        #expect(left.value(of: "amount", default: 0, atOffset: Time(seconds: 2)) == 20)
        #expect(right.value(of: "amount", default: 0, atOffset: .zero) == 20, "no jump at the cut")
        #expect(right.value(of: "amount", default: 0, atOffset: Time(seconds: 1)) == 30)
        #expect(left.id != right.id)
    }

    @Test func labsRoundTripAndOlderClipsLoad() throws {
        var state = ProjectState()
        var clip = Clip.text(at: .zero, duration: Time(seconds: 2))
        clip.text = nil
        clip.generator = LabEffect(experimentID: "gradient", values: ["angle": 45])
        var shader = LabEffect(experimentID: "customShader")
        shader.source = "// my code"
        shader.setKeyframe("a", at: .zero, value: 0.25)
        clip.labs = [shader]
        state.tracks[0].clips = [clip]
        #expect(try ProjectState.decode(state.encoded()) == state)

        // A clip saved before Labs existed.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as! [String: Any]
        json.removeValue(forKey: "labs")
        json.removeValue(forKey: "generator")
        let old = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.labs.isEmpty && old.generator == nil)
    }

    @Test func generatorClipsRenderThroughTheTimeline() async throws {
        var state = ProjectState(settings: ProjectSettings(name: "T", width: 640, height: 360, frameRate: 30),
                                 videoTracks: 1, audioTracks: 0, textTracks: 0)
        var clip = Clip(id: UUID(), mediaID: Clip.generatedMediaID, name: "Solid", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        clip.generator = LabEffect(experimentID: "solid", values: ["hue": 120, "saturation": 1, "brightness": 1])
        state.tracks[0].clips = [clip]
        let output = try await CompositionBuilder.build(state, urls: [:])
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let p = try TextRenderTests.pixel(image, x: 320, y: 180)
        #expect(p.g > 200 && p.r < 40 && p.b < 40, "a green frame, not an offline slate: \(p)")
    }
}

@MainActor struct LabsEditingTests {
    @Test func labsWorkInThePlaygroundAndGraduateToEdit() {
        let (editor, undo, original) = PlaygroundTests.makeProject()
        editor.sendToPlayground([original.id])
        let playground = editor.playground!
        let sandbox = playground.editor
        let copy = sandbox.state.allClips[0]
        sandbox.applyLabEffect("rgbSplit", to: [copy.id])
        let effectID = sandbox.state.clip(copy.id)!.labs[0].id

        // A slider drag is one undo step in the Playground.
        playground.undoManager.removeAllActions()
        sandbox.beginAdjustment()
        for v in [5.0, 10, 30] { sandbox.setLabValue(v, parameter: "amount", of: effectID, in: copy.id) }
        sandbox.endAdjustment("Change Split")
        #expect(sandbox.state.clip(copy.id)!.labs[0].values["amount"] == 30)
        #expect(playground.undoManager.canUndo)

        // Keyframing at the playhead.
        sandbox.playback.seek(to: Time(seconds: 1))
        sandbox.toggleLabKeyframe("amount", of: effectID, in: copy.id)
        #expect(sandbox.state.clip(copy.id)!.labs[0].isAnimated("amount"))

        // Switched off in Labs: drawn without it, but still on the clip.
        playground.setExperiment("rgbSplit", enabled: false)
        #expect(sandbox.playback.prepared(sandbox.state).clip(copy.id)?.labs[0].isEnabled == false)
        #expect(sandbox.state.clip(copy.id)?.labs[0].isEnabled == true)
        playground.setExperiment("rgbSplit", enabled: true)

        // The project never saw any of it…
        #expect(editor.state.clip(original.id)!.labs.isEmpty && !undo.canUndo)
        // …until it's promoted.
        PlaygroundTests.step(undo) { sandbox.applySettingsToProject(from: copy.id, onto: original.id) }
        #expect(editor.state.clip(original.id)!.labs.first?.experimentID == "rgbSplit")

        // Generators promote as new clips.
        sandbox.addGenerator("bars")
        let bars = sandbox.selection.first!
        PlaygroundTests.step(undo) { sandbox.promoteToEdit([bars]) }
        #expect(editor.state.allClips.contains { $0.generator?.experimentID == "bars" })
    }
}
