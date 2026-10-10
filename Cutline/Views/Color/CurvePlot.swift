import SwiftUI

/// An editable curve through points in a unit square (y up). Click to add a point,
/// drag to move one (one drag = one undo step), double-click a point to remove it.
struct CurvePlot<Background: View>: View {
    let points: [CurvePoint]
    /// The curve's y at an x, for drawing.
    let curve: (Double) -> Double
    let color: Color
    /// RGB curves keep a point at each end, which can only move up and down.
    var fixedEnds = true
    /// Other curves drawn faintly behind this one.
    var ghosts: [(curve: (Double) -> Double, color: Color)] = []
    @ViewBuilder var background: Background
    let onBegin: () -> Void
    let onChange: ([CurvePoint]) -> Void
    let onEnd: (_ actionName: String) -> Void
    /// A single, complete edit (adding or removing a point by clicking).
    let onCommit: ([CurvePoint], _ actionName: String) -> Void

    @State private var dragIndex: Int?
    @State private var working: [CurvePoint] = []
    @State private var actionName = "Move Curve Point"

    private static var hitRadius: CGFloat { 10 }
    /// Room around the plot so points at the edges are fully visible.
    private static var inset: CGFloat { 6 }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                background
                Canvas { context, size in
                    // Grid in quarters.
                    var grid = Path()
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        grid.move(to: CGPoint(x: size.width * f, y: 0))
                        grid.addLine(to: CGPoint(x: size.width * f, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: size.height * f))
                        grid.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    }
                    context.stroke(grid, with: .color(Theme.toneCurveGrid), lineWidth: 1)

                    for ghost in ghosts {
                        context.stroke(path(ghost.curve, in: size), with: .color(ghost.color.opacity(0.35)), lineWidth: 1)
                    }
                    context.stroke(path(curve, in: size), with: .color(color), lineWidth: 1.5)

                    for (index, point) in points.enumerated() {
                        let p = location(of: point, in: size)
                        let r: CGFloat = index == dragIndex ? 5 : 4
                        let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                        context.fill(dot, with: .color(Theme.curvePlot))
                        context.stroke(dot, with: .color(color), lineWidth: 1.5)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 4))
            .contentShape(.rect)
            .gesture(drag(in: size))
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { removePoint(near: $0.location, in: size) }
                    .exclusively(before: SpatialTapGesture(count: 1).onEnded { addPoint(at: $0.location, in: size) })
            )
        }
    }

    private func path(_ curve: (Double) -> Double, in size: CGSize) -> Path {
        var path = Path()
        let samples = 160
        for i in 0...samples {
            let x = Double(i) / Double(samples)
            let p = location(of: CurvePoint(x: x, y: curve(x)), in: size)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func location(of point: CurvePoint, in size: CGSize) -> CGPoint {
        let i = Self.inset
        return CGPoint(x: i + point.x * (size.width - 2 * i), y: i + (1 - point.y) * (size.height - 2 * i))
    }

    private func unit(_ location: CGPoint, in size: CGSize) -> CurvePoint {
        let i = Self.inset
        return CurvePoint(x: Double((location.x - i) / max(size.width - 2 * i, 1)).clamped(to: 0...1),
                          y: Double(1 - (location.y - i) / max(size.height - 2 * i, 1)).clamped(to: 0...1))
    }

    private func nearest(to target: CGPoint, in list: [CurvePoint], size: CGSize) -> Int? {
        let distances = list.enumerated().map { item -> (Int, CGFloat) in
            let p = location(of: item.element, in: size)
            return (item.offset, hypot(p.x - target.x, p.y - target.y))
        }
        guard let best = distances.min(by: { $0.1 < $1.1 }), best.1 <= Self.hitRadius else { return nil }
        return best.0
    }

    private func isEnd(_ index: Int, in list: [CurvePoint]) -> Bool {
        fixedEnds && (index == 0 || index == list.count - 1)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragIndex == nil {
                    working = points.sorted { $0.x < $1.x }
                    if let hit = nearest(to: value.startLocation, in: working, size: size) {
                        dragIndex = hit
                        actionName = "Move Curve Point"
                    } else {
                        let new = unit(value.startLocation, in: size)
                        working.append(new)
                        working.sort { $0.x < $1.x }
                        dragIndex = working.firstIndex(of: new)
                        actionName = "Add Curve Point"
                    }
                    onBegin()
                }
                guard let index = dragIndex, working.indices.contains(index) else { return }
                var moved = unit(value.location, in: size)
                if isEnd(index, in: working) {
                    moved.x = working[index].x
                } else {
                    // Keep points in order, a little apart.
                    let low = index > 0 ? working[index - 1].x + 0.01 : 0
                    let high = index < working.count - 1 ? working[index + 1].x - 0.01 : 1
                    moved.x = low <= high ? moved.x.clamped(to: low...high) : working[index].x
                }
                working[index] = moved
                onChange(working)
            }
            .onEnded { _ in
                if dragIndex != nil { onEnd(actionName) }
                dragIndex = nil
            }
    }

    private func addPoint(at location: CGPoint, in size: CGSize) {
        let list = points.sorted { $0.x < $1.x }
        guard nearest(to: location, in: list, size: size) == nil else { return }
        // On the curve where clicked, so adding a point never changes the shape by itself.
        let x = unit(location, in: size).x
        var new = list
        new.append(CurvePoint(x: x, y: curve(x).clamped(to: 0...1)))
        onCommit(new.sorted { $0.x < $1.x }, "Add Curve Point")
    }

    private func removePoint(near location: CGPoint, in size: CGSize) {
        var list = points.sorted { $0.x < $1.x }
        guard let index = nearest(to: location, in: list, size: size), !isEnd(index, in: list) else { return }
        list.remove(at: index)
        onCommit(list, "Remove Curve Point")
    }
}
