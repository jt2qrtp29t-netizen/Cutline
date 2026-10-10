import SwiftUI

extension View {
    /// Recessed text field well used throughout the app. Apply to a `TextField`.
    func themedField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.recessed, in: .rect(cornerRadius: Theme.Metrics.controlCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius)
                    .strokeBorder(Theme.border)
            }
            .foregroundStyle(Theme.textPrimary)
    }
}

/// Small uppercase section title.
struct SectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// A label / control row with a fixed-width label column.
struct FieldRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 90
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: labelWidth, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Plain icon button with a hover highlight on the raised surface color.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var isActive = false
    var size: CGFloat = 26
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                .frame(width: size, height: size)
                .background(isHovering ? Theme.raisedHover : Theme.raised.opacity(0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}
