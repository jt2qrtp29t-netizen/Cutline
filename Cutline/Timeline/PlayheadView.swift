import SwiftUI

/// The rounded head of the playhead, drawn on the ruler.
nonisolated struct PlayheadHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        // A rounded tab that narrows to a point at the bottom.
        let r: CGFloat = 3
        let shoulder = rect.maxY - rect.width * 0.55
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulder))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: shoulder))
        path.closeSubpath()
        return path
    }
}

/// Playhead head plus the short line segment inside the ruler.
/// Positioned relative to the ruler's visible window.
struct RulerPlayhead: View {
    let playback: PlaybackController
    let layout: TimelineLayout
    let originX: CGFloat

    static let headSize = CGSize(width: 13, height: 17)

    var body: some View {
        let x = layout.x(for: playback.currentTime) - originX
        ZStack(alignment: .top) {
            PlayheadLine()
                .frame(height: Theme.Metrics.rulerHeight)
            PlayheadHeadShape()
                .fill(Theme.playhead)
                .shadow(color: Theme.playheadGlow, radius: 4)
                .overlay {
                    PlayheadHeadShape().stroke(Theme.playheadOutline, lineWidth: 1.5)
                }
                .frame(width: Self.headSize.width, height: Self.headSize.height)
                .padding(.top, 3)
        }
        .frame(width: 20)
        .offset(x: x - 10)
        .allowsHitTesting(false)
    }
}

/// The vertical playhead line: green core, crisp black outline, soft glow.
struct PlayheadLine: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Theme.playheadGlow)
                .frame(width: 5)
                .blur(radius: 3)
            Rectangle()
                .fill(Theme.playheadOutline)
                .frame(width: 4)
            Rectangle()
                .fill(Theme.playhead)
                .frame(width: 2)
        }
    }
}

/// The playhead line inside the lanes; it has a wider grab area for scrubbing.
struct LanesPlayhead: View {
    let editor: EditorController
    let playback: PlaybackController
    let layout: TimelineLayout
    let height: CGFloat
    /// Left edge of the visible area, to convert the pointer to viewport coordinates.
    let originX: CGFloat

    @State private var isHovering = false

    var body: some View {
        let x = layout.x(for: playback.currentTime)
        PlayheadLine()
            .frame(width: 12, height: height)
            .contentShape(.rect)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineCoordinateSpace.lanes))
                    .onChanged { value in
                        editor.dragPlayhead(viewportX: value.location.x - originX, contentX: value.location.x, layout: layout)
                    }
                    .onEnded { _ in editor.endPlayheadDrag() }
            )
            .offset(x: x - 6)
    }
}

enum TimelineCoordinateSpace {
    static let lanes = "timeline.lanes"
}

/// Pages the timeline during playback so the playhead stays in view.
/// Isolated in its own view so 60 Hz playhead updates don't re-render the timeline.
struct PlayheadFollower: View {
    let playback: PlaybackController
    let layout: TimelineLayout
    let visibleRect: CGRect
    let scrollTo: (CGFloat) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: playback.currentTime) { _, time in
                guard playback.isPlaying, visibleRect.width > 0 else { return }
                let x = layout.x(for: time)
                if x > visibleRect.maxX - 24 || x < visibleRect.minX {
                    scrollTo(max(0, x - 24))
                }
            }
    }
}
