import SwiftUI

/// How each animatable parameter is shown and edited.
extension AnimatableProperty {
    var displayScale: Double {
        switch self {
        case .scale, .opacity, .contrast, .saturation, .lutIntensity: 100
        case .brightness, .temperature, .tint, .highlights, .shadows: 100
        case .liftMaster, .gammaMaster, .gainMaster, .offsetMaster: 100
        case .volume, .pan, .speed: 100
        default: 1
        }
    }

    var unit: String {
        switch self {
        case .positionX, .positionY: "px"
        case .scale, .opacity: "%"
        case .rotation, .yaw, .pitch: "°"
        case .exposure: "EV"
        case .contrast, .saturation, .lutIntensity, .volume, .speed: "%"
        default: ""
        }
    }

    var fractionDigits: Int {
        switch self {
        case .opacity, .contrast, .saturation, .lutIntensity, .volume, .pan, .speed: 0
        case .exposure: 2
        default: 1
        }
    }

    /// Value change per point dragged (⌥ for 10× finer).
    var unitsPerPoint: Double {
        switch self {
        case .positionX, .positionY: 1
        case .scale: 0.001
        case .opacity: 0.005
        case .rotation, .yaw, .pitch: 0.25
        default: 0.005
        }
    }

    /// The range offered by sliders; position depends on the project size.
    func sliderRange(for settings: ProjectSettings) -> ClosedRange<Double> {
        switch self {
        case .positionX: -Double(settings.width)...Double(settings.width)
        case .positionY: -Double(settings.height)...Double(settings.height)
        case .rotation: -360...360
        case .speed: 0.25...4
        default: range
        }
    }

    func formatted(_ value: Double) -> String {
        String(format: "%.\(fractionDigits)f\(unit == "%" ? "%%" : unit.isEmpty ? "" : " " + unit)", value * displayScale)
    }
}

extension Easing {
    var title: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In-Out"
        case .bezier: "Custom"
        }
    }

    static let presets: [Easing] = [.linear, .easeIn, .easeOut, .easeInOut]

    func isSameKind(as other: Easing) -> Bool {
        switch (self, other) {
        case (.bezier, .bezier): true
        default: self == other
        }
    }
}

/// The keyframe marker.
nonisolated struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// A diamond: filled when on, outlined when off.
struct KeyframeDiamond: View {
    var isFilled: Bool
    var isSelected = false
    var size: CGFloat = 10

    var body: some View {
        DiamondShape()
            .fill(isFilled ? (isSelected ? Theme.keyframeSelected : Theme.keyframe) : Theme.keyframe.opacity(0))
            .overlay {
                DiamondShape().stroke(isSelected ? Theme.keyframeSelected : Theme.keyframe, lineWidth: 1.2)
            }
            .frame(width: size, height: size)
    }
}

/// Tab bar under the title bar.
struct WorkspaceTabBar: View {
    let editor: EditorController
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Workspace.allCases) { workspace in
                let isSelected = editor.workspace == workspace
                Button {
                    withAnimation(.snappy(duration: 0.2)) { editor.workspace = workspace }
                } label: {
                    Label(workspace.title, systemImage: workspace.symbolName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.raised)
                                    .overlay(alignment: .bottom) {
                                        Capsule().fill(Theme.accent).frame(height: 2).padding(.horizontal, 10)
                                    }
                                    .matchedGeometryEffect(id: "tab", in: selection)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(workspace.title) (⌘\(Workspace.allCases.firstIndex(of: workspace)! + 1))")
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

