import AVFoundation
import VideoToolbox
import Testing
@testable import Cutline

struct ExportSettingsTests {
    let project = ProjectSettings(name: "Trip", width: 1920, height: 1080, frameRate: 30)

    @Test func presetsMapToTheirSettings() {
        var base = ExportSettings()
        base.range = .inOut
        base.fileName = "Keep me"
        let fourK = ExportPreset.youTube4K.applied(to: base)
        #expect(fourK.resolution.size(for: project) == (3840, 2160) && fourK.frameRate(for: project) == 60)
        #expect(fourK.codec == .hevc && fourK.container == .mp4 && fourK.presetID == "youtube4k")
        #expect(fourK.range == .inOut && fourK.fileName == "Keep me", "range and file name are kept")

        let hd = ExportPreset.youTube1080.applied(to: base)
        #expect(hd.resolution.size(for: project) == (1920, 1080) && hd.frameRate == 60 && hd.codec == .h264)

        let vertical = ExportPreset.vertical.applied(to: base)
        #expect(vertical.resolution.size(for: project) == (1080, 1920) && vertical.frameRate(for: project) == 30)
        #expect(ExportPreset.square.applied(to: base).resolution.size(for: project) == (1080, 1080))

        let quick = ExportPreset.quickPreview.applied(to: base)
        #expect(quick.resolution.size(for: project) == (960, 540) && quick.quality < 0.3)

        let master = ExportPreset.proRes.applied(to: base)
        #expect(master.codec == .proRes422 && master.effectiveContainer == .mov)
        #expect(master.resolution.size(for: project) == (1920, 1080))

        #expect(ExportPreset.custom.applied(to: fourK).codec == .hevc, "Custom keeps the current settings")
        #expect(Set(ExportPreset.all.map(\.id)).count == ExportPreset.all.count)
    }

    @Test func sizesKeepTheProjectShapeAndAreEven() {
        let wide = ProjectSettings(name: "W", width: 2560, height: 1080, frameRate: 24)
        #expect(ExportResolution.p1080.size(for: wide) == (2560, 1080))
        let odd = ProjectSettings(name: "O", width: 1281, height: 721, frameRate: 24)
        #expect(ExportResolution.project.size(for: odd) == (1282, 722))
        #expect(ExportResolution.custom(width: 3, height: 3).size(for: project) == (16, 16))
    }

    @Test func rangesComeFromTheTimelineInOutOrSelection() {
        var settings = ExportSettings()
        let duration = Time(seconds: 10)
        #expect(settings.timeRange(timelineDuration: duration, selection: []) == TimeRange(start: .zero, end: duration))

        settings.range = .inOut
        settings.inPoint = Time(seconds: 2)
        settings.outPoint = Time(seconds: 5)
        #expect(settings.timeRange(timelineDuration: duration, selection: []) == TimeRange(start: Time(seconds: 2), end: Time(seconds: 5)))
        settings.outPoint = Time(seconds: 30)
        #expect(settings.timeRange(timelineDuration: duration, selection: [])?.end == duration, "clamped to the timeline")
        settings.outPoint = Time(seconds: 1)
        #expect(settings.timeRange(timelineDuration: duration, selection: []) == nil, "out before in is empty")

        settings.range = .selection
        let a = Clip(id: UUID(), mediaID: UUID(), name: "a", start: Time(seconds: 3), duration: Time(seconds: 1), sourceStart: .zero)
        let b = Clip(id: UUID(), mediaID: UUID(), name: "b", start: Time(seconds: 6), duration: Time(seconds: 2), sourceStart: .zero)
        #expect(settings.timeRange(timelineDuration: duration, selection: [b, a]) == TimeRange(start: Time(seconds: 3), end: Time(seconds: 8)))
        #expect(settings.timeRange(timelineDuration: duration, selection: []) == nil)
        #expect(settings.timeRange(timelineDuration: .zero, selection: []) == nil)
    }

    @Test func estimatesScaleWithQualitySizeAndLength() {
        var settings = ExportPreset.youTube1080.applied(to: ExportSettings())
        settings.quality = 0.1
        let low = settings.estimatedBytes(seconds: 60, project: project)
        settings.quality = 1
        let high = settings.estimatedBytes(seconds: 60, project: project)
        #expect(high > low * 2)
        #expect(settings.estimatedBytes(seconds: 120, project: project) == high * 2)
        settings.codec = .hevc
        #expect(settings.estimatedBytes(seconds: 60, project: project) < high)
        // ProRes 422 at 1080p30: about 1.1 GB a minute.
        let prores = ExportPreset.proRes.applied(to: ExportSettings()).estimatedBytes(seconds: 60, project: project)
        #expect(prores > 1.0e9 && prores < 1.3e9)
    }

    @Test func settingsAreSavedWithTheProjectAndOldProjectsLoad() throws {
        var state = ProjectState()
        state.exportSettings = ExportPreset.vertical.applied(to: state.exportSettings)
        state.exportSettings.fit = .fit
        state.exportSettings.inPoint = Time(seconds: 1)
        state.exportSettings.folderPath = "/Users/someone/Movies"
        #expect(try ProjectState.decode(state.encoded()) == state)

        var json = try JSONSerialization.jsonObject(with: state.encoded()) as! [String: Any]
        json.removeValue(forKey: "exportSettings")
        let old = try ProjectState.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.exportSettings == ExportSettings())
    }

    @Test func fasterEncodingAsksTheHardwareEncoderForSpeed() {
        let key = kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
        let project = ProjectSettings(name: "P", width: 1920, height: 1080, frameRate: 30)
        func asksForSpeed(_ s: ExportSettings) -> Bool {
            let video = ExportRenderer.videoSettings(s, width: 1920, height: 1080, project: project)
            return (video[AVVideoCompressionPropertiesKey] as? [String: Any])?[key] as? Bool == true
        }
        var settings = ExportPreset.youTube4K.applied(to: ExportSettings())
        #expect(settings.fastEncoding && asksForSpeed(settings), "on by default")
        settings.fastEncoding = false
        #expect(!asksForSpeed(settings))
        settings.fastEncoding = true
        settings.hardwareEncoding = false
        #expect(!asksForSpeed(settings), "only for the hardware encoder")
        // Saved settings from before the option load with it on.
        var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportSettings())) as! [String: Any]
        json.removeValue(forKey: "fastEncoding")
        let old = try! JSONDecoder().decode(ExportSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.fastEncoding)
        #expect(old.networkOptimized)

        // The faster mode gets 20% more bitrate to keep the same quality, and only HEVC has it.
        var hevc = ExportPreset.youTube4K.applied(to: ExportSettings())
        let fastRate = hevc.videoBitrate(for: project)
        hevc.fastEncoding = false
        #expect(abs(fastRate / hevc.videoBitrate(for: project) - ExportSettings.fastEncodingBitrateFactor) < 0.001)
        var h264 = ExportPreset.youTube1080.applied(to: ExportSettings())
        h264.fastEncoding = true
        #expect(!h264.usesFastEncoding && !asksForSpeed(h264))
    }

    @Test func timeEstimatesFollowTheEncoderAndTheWork() {
        let project4K = ProjectSettings(name: "P", width: 3840, height: 2160, frameRate: 60)
        var settings = ExportPreset.youTube4K.applied(to: ExportSettings())
        func estimate(_ s: ExportSettings, complexity: Double = 1) -> Double {
            ExportTimeEstimate.predicted(frames: 18_000, width: 3840, height: 2160, project: project4K,
                                         encoder: .init(s), complexity: complexity)
        }
        // Five minutes of 4K60 HEVC: about three minutes in the faster mode, five without
        // (measured on an M4), not half an hour.
        #expect((150...210).contains(estimate(settings)), "\(estimate(settings))")
        settings.fastEncoding = false
        #expect((290...360).contains(estimate(settings)), "\(estimate(settings))")
        settings.hardwareEncoding = false
        #expect(estimate(settings) > 3_000, "software HEVC is far slower")
        settings = ExportPreset.proRes.applied(to: ExportSettings())
        #expect(estimate(settings) < estimate(ExportPreset.youTube4K.applied(to: ExportSettings())))
        // Heavy frames make drawing the slower stage.
        #expect(estimate(settings, complexity: 6) > estimate(settings) * 2)

        // Complexity grows with layers, grades and Labs effects in the range.
        let media = MediaItem(id: UUID(), name: "m", path: "/m.mov", duration: Time(seconds: 10), width: 3840, height: 2160, frameRate: 60, hasAudio: false)
        var state = ProjectState(settings: project4K, videoTracks: 2, audioTracks: 0, textTracks: 0)
        state.media = [media]
        var clip = Clip(id: UUID(), mediaID: media.id, name: "A", start: .zero, duration: Time(seconds: 10), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        let range = TimeRange(start: .zero, end: Time(seconds: 10))
        let plain = ExportTimeEstimate.complexity(of: state, in: range)
        clip.color.saturation = 1.3
        clip.labs = [LabEffect(experimentID: "noise")]
        state.tracks[0].clips = [clip]
        let graded = ExportTimeEstimate.complexity(of: state, in: range)
        clip.id = UUID()
        state.tracks[1].clips = [clip]
        let layered = ExportTimeEstimate.complexity(of: state, in: range)
        #expect(plain < graded && graded < layered)
        #expect(ExportTimeEstimate.complexity(of: state, in: TimeRange(start: Time(seconds: 20), end: Time(seconds: 30))) == 1)
    }

    @Test func estimatesLearnFromRealExports() throws {
        let defaults = try #require(UserDefaults(suiteName: "cutline.tests.estimate"))
        defer { defaults.removePersistentDomain(forName: "cutline.tests.estimate") }
        ExportTimeEstimate.resetLearning(defaults: defaults)
        #expect(ExportTimeEstimate.correction(for: .hevcFast, defaults: defaults) == 1)
        // An export that took twice as long as predicted moves that encoder's estimates.
        ExportTimeEstimate.learn(encoder: .hevcFast, predicted: 60, actual: 120, defaults: defaults)
        #expect(ExportTimeEstimate.correction(for: .hevcFast, defaults: defaults) == 2)
        ExportTimeEstimate.learn(encoder: .hevcFast, predicted: 60, actual: 60, defaults: defaults)
        #expect(ExportTimeEstimate.correction(for: .hevcFast, defaults: defaults) == 1.5)
        #expect(ExportTimeEstimate.correction(for: .proRes, defaults: defaults) == 1, "other encoders unaffected")
        // Tiny exports (mostly overhead) and wild outliers can't throw it far off.
        ExportTimeEstimate.learn(encoder: .h264, predicted: 0.4, actual: 1.5, defaults: defaults)
        #expect(ExportTimeEstimate.correction(for: .h264, defaults: defaults) == 1)
        ExportTimeEstimate.learn(encoder: .h264, predicted: 10, actual: 1_000, defaults: defaults)
        #expect(ExportTimeEstimate.correction(for: .h264, defaults: defaults) == 4)
    }
}
