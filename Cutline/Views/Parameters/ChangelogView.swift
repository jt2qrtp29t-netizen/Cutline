import SwiftUI

/// The Changelog window: what every version of Cutline added.
struct ChangelogView: View {
    var body: some View {
        ScrollView {
            ChangelogList(entries: Changelog.entries)
                .padding(16)
        }
        .frame(minWidth: 460, idealWidth: 540, minHeight: 420, idealHeight: 680)
        .background(Theme.background)
    }
}

struct ChangelogList: View {
    let entries: [Changelog.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(entries) { entry in
                ChangelogEntryView(entry: entry, isCurrent: entry.version == AppVersion.short)
            }
        }
    }
}

private struct ChangelogEntryView: View {
    let entry: Changelog.Entry
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("v\(entry.version)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Theme.background : Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(isCurrent ? Theme.accent : Theme.recessed, in: .capsule)
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                ForEach(entry.tags) { tag in
                    ChangelogTagBadge(tag: tag)
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(entry.changes, id: \.self) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(Theme.textTertiary)
                            .frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        Text(change)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: .rect(cornerRadius: 8))
        .overlay {
            if isCurrent { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.5)) }
        }
    }
}

/// FEATURE or BUG FIX, next to a version's title.
struct ChangelogTagBadge: View {
    let tag: Changelog.Tag

    var body: some View {
        let color = tag == .feature ? Theme.changelogFeature : Theme.changelogBugFix
        Text(tag.rawValue)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: .rect(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.45), lineWidth: 0.5) }
            .fixedSize()
    }
}
