import SwiftUI

/// A hairline divider that resizes the adjacent panel when dragged.
struct PanelDivider: View {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    @Binding var size: Double
    let range: ClosedRange<Double>
    /// +1 when dragging right/down grows the panel, -1 when it shrinks it.
    var direction: Double = 1

    @State private var startSize: Double?
    @State private var isHovering = false

    var body: some View {
        let isVertical = axis == .vertical
        Rectangle()
            .fill(isHovering || startSize != nil ? Theme.raisedHover : Theme.border)
            .frame(width: isVertical ? 1 : nil, height: isVertical ? nil : 1)
            .overlay {
                // Wider invisible hit area.
                Rectangle()
                    .fill(Theme.background.opacity(0.001))
                    .frame(width: isVertical ? 7 : nil, height: isVertical ? nil : 7)
                    .contentShape(.rect)
                    .pointerStyle(isVertical ? .columnResize : .rowResize)
                    .onHover { isHovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = startSize ?? size
                                if startSize == nil { startSize = size }
                                let delta = isVertical ? value.translation.width : value.translation.height
                                size = (base + delta * direction).clamped(to: range)
                            }
                            .onEnded { _ in startSize = nil }
                    )
            }
            .zIndex(10)
    }
}
