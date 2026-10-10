import SwiftUI

/// Every keyboard shortcut and modifier gesture in Cutline, grouped for the
/// Keyboard Shortcuts window. Keep in step with `CutlineCommands`.
enum ShortcutList {
    struct Item: Identifiable {
        let keys: String
        let action: String
        var id: String { action }
    }

    struct Group: Identifiable {
        let title: String
        let symbolName: String
        let items: [Item]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Project", symbolName: "folder", items: [
            Item(keys: "⌘N", action: "New Project…"),
            Item(keys: "⌘O", action: "Open…"),
            Item(keys: "⌘S", action: "Save"),
            Item(keys: "⌘I", action: "Import Media…"),
            Item(keys: "⇧⌘E", action: "Export…"),
            Item(keys: "⌘W", action: "Close Window"),
            Item(keys: "⌘,", action: "Parameters…"),
            Item(keys: "⌘/", action: "Keyboard Shortcuts"),
        ]),
        Group(title: "Workspace", symbolName: "rectangle.3.group", items: [
            Item(keys: "⌘1 – ⌘5", action: "Edit, Effects, Color, Playground, Export"),
            Item(keys: "Scroll sideways", action: "Next or previous tab (e.g. a mouse’s thumb wheel)"),
            Item(keys: "⌘+  /  ⌘−", action: "Zoom the timeline in or out"),
            Item(keys: "⌥-click zoom buttons", action: "Zoom in smaller steps"),
            Item(keys: "Pinch", action: "Zoom the timeline around the pointer"),
            Item(keys: "⌥⌘M", action: "Minimize Window"),
        ]),
        Group(title: "Playback", symbolName: "play.circle", items: [
            Item(keys: "Space", action: "Play / Pause"),
            Item(keys: "←  /  →", action: "Previous / Next Frame"),
            Item(keys: "Home  /  End", action: "Go to Start / End"),
            Item(keys: "⌥-drag playhead", action: "Move the playhead one frame at a time"),
            Item(keys: "⇧⌘M", action: "Mute All Audio"),
        ]),
        Group(title: "Editing", symbolName: "scissors", items: [
            Item(keys: "⌘Z  /  ⇧⌘Z", action: "Undo / Redo"),
            Item(keys: "⌘B", action: "Blade at Playhead"),
            Item(keys: "⌫", action: "Delete the selected clips, transition or keyframes"),
            Item(keys: "⇧-click  /  ⌘-click", action: "Add or remove a clip from the selection"),
            Item(keys: "⌥-click", action: "Select one clip without its linked clips"),
            Item(keys: "⌥⌘L", action: "Link / Unlink Clips"),
            Item(keys: "⇧⌘L", action: "Lock / Unlock Clips"),
            Item(keys: "⇧⌘N", action: "Snapping on / off"),
            Item(keys: "⇧⌘T", action: "Add Text"),
        ]),
        Group(title: "Markers", symbolName: "bookmark", items: [
            Item(keys: "⌘M", action: "Add Marker…"),
            Item(keys: "⌥⌘←  /  ⌥⌘→", action: "Previous / Next Marker"),
        ]),
        Group(title: "Adjusting Values", symbolName: "slider.horizontal.3", items: [
            Item(keys: "⌥-drag", action: "Fine control (10× smaller steps)"),
            Item(keys: "⇧-drag", action: "Coarse control (10× bigger steps)"),
            Item(keys: "↑  /  ↓", action: "Step the value in a number field"),
        ]),
    ]
}

struct KeyboardShortcutsView: View {
    @State private var search = ""

    private var groups: [ShortcutList.Group] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ShortcutList.groups }
        return ShortcutList.groups.compactMap { group in
            let items = group.items.filter {
                $0.action.localizedCaseInsensitiveContains(query) || $0.keys.localizedCaseInsensitiveContains(query)
            }
            return items.isEmpty ? nil : ShortcutList.Group(title: group.title, symbolName: group.symbolName, items: items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search shortcuts", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.recessed, in: .rect(cornerRadius: 6))
            .padding(12)
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                ShortcutGroupsView(groups: groups, search: search)
                .padding(16)
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 640)
        .background(Theme.background)
    }
}

/// The grouped shortcut lists.
struct ShortcutGroupsView: View {
    let groups: [ShortcutList.Group]
    var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Label(group.title, systemImage: group.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                    VStack(spacing: 0) {
                        ForEach(group.items) { item in
                            ShortcutRow(item: item)
                            if item.id != group.items.last?.id {
                                Rectangle().fill(Theme.border).frame(height: 1)
                            }
                        }
                    }
                    .background(Theme.raised, in: .rect(cornerRadius: 8))
                }
            }
            if groups.isEmpty {
                Text("No shortcuts match “\(search)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            }
        }
    }
}

private struct ShortcutRow: View {
    let item: ShortcutList.Item

    var body: some View {
        HStack(spacing: 12) {
            Text(item.action)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.keys)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.recessed, in: .rect(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
