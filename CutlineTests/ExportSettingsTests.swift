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
    }
}
