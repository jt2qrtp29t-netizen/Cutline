import SwiftUI

/// Time ruler. Draws only the visible window of the timeline.
struct RulerView: View {
    let editor: EditorController
    let layout: TimelineLayout
    /// Visible rect of the lanes scroll view, in content coordinates.
    let visibleRect: CGRect

    var body: some View {
        let scale = RulerScale(pixelsPerSecond: layout.pixelsPerSecond, fps: editor.fps)
        let originX = visibleRect.minX
        let fps = editor.fps
        let pps = layout.pixelsPerSecond

        Canvas { context, size in
            let startSeconds = Double(originX) / pps
            let endSeconds = Double(originX + size.width) / pps

            func ticks(every step: Double) -> StrideThrough<Int> {
                stride(from: Int((startSeconds / step).rounded(.down)), through: Int((endSeconds / step).rounded(.up)), by: 1)
            }

            if scale.minor > 0 {
                var path = Path()
                for i in ticks(every: scale.minor) {
                    let x = CGFloat(Double(i) * scale.minor * pps) - originX
                    path.addRect(CGRect(x: x.rounded(), y: size.height - 5, width: 1, height: 5))
                }
                context.fill(path, with: .color(Theme.rulerTickMinor))
            }

            var majorPath = Path()
            for i in ticks(every: scale.major) where i >= 0 {
                let seconds = Double(i) * scale.major
                let x = CGFloat(seconds * pps) - originX
                majorPath.addRect(CGRect(x: x.rounded(), y: size.height - 11, width: 1, height: 11))
                let label = Timecode.rulerLabel(for: Time(seconds: seconds), fps: fps, showFrames: scale.showsFrames)
                context.draw(
                    Text(label)
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.rulerText),
                    at: CGPoint(x: x + 4, y: 9),
                    anchor: .leading
                )
            }
            context.fill(majorPath, with: .color(Theme.rulerTickMajor))
        }
        .background(Theme.background)
        .contentShape(.rect)
        .gesture(
            // Click to jump, drag to scrub.
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    editor.dragPlayhead(viewportX: value.location.x, contentX: value.location.x + originX, layout: layout)
                }
                .onEnded { _ in editor.endPlayheadDrag() }
        )
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                RulerMarkers(editor: editor, layout: layout, originX: originX, width: geometry.size.width)
            }
        }
        .overlay(alignment: .topLeading) {
            RulerPlayhead(playback: editor.playback, layout: layout, originX: originX)
        }
        .clipped()
    }
}
