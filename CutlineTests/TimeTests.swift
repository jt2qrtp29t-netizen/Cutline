import Foundation
import Testing
@testable import Cutline

struct TimeTests {
    @Test func frameBoundariesAreExact() {
        for fps in ProjectSettings.supportedFrameRates {
            let frame = Time.frame(fps: fps)
            #expect(frame.ticks * Int64(fps) == Time.ticksPerSecond)
        }
    }

    @Test func snapsToNearestFrame() {
        let t = Time(seconds: 1.02)
        #expect(t.snappedToFrame(fps: 25) == Time(seconds: 1.04) || t.snappedToFrame(fps: 25) == Time(seconds: 1.0))
        #expect(Time(seconds: 0.51).snappedToFrame(fps: 2 * 30) == Time(ticks: 310))
    }

    @Test func timecodeFormatting() {
        #expect(Timecode.string(for: Time(seconds: 61.5), fps: 30) == "01:01:15")
        #expect(Timecode.string(for: Time(seconds: 3600), fps: 24) == "01:00:00:00")
    }

    @Test func projectStateRoundTrips() throws {
        var state = ProjectState(settings: .default)
        state.markers.append(Marker(id: .init(), time: Time(seconds: 2), name: "A", color: .red))
        let decoded = try ProjectState.decode(state.encoded())
        #expect(decoded == state)
    }
}
