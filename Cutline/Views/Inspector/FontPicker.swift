import AppKit
import SwiftUI

/// Every font Font Book lists: families installed on the Mac (including fonts you
/// added in Font Book) and Apple's downloadable fonts, which download on first use.
enum FontCatalog {
    struct Family: Hashable, Identifiable {
        let name: String
        /// False for Apple fonts Font Book offers but that haven't been downloaded.
        let isInstalled: Bool
        var id: String { name }
    }

    static func allFamilies() -> [Family] {
        let installed = Set(families())
        let downloadable = downloadableFamilies().subtracting(installed)
        return (installed.map { Family(name: $0, isInstalled: true) } + downloadable.map { Family(name: $0, isInstalled: false) })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func downloadableFamilies() -> Set<String> {
        let query = CTFontDescriptorCreateWithAttributes([kCTFontDownloadableAttribute: true] as CFDictionary)
        let matches = (CTFontDescriptorCreateMatchingFontDescriptors(query, nil) as? [CTFontDescriptor]) ?? []
        return Set(matches.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
            .filter { !$0.hasPrefix(".") })
    }

    /// Downloads one of Apple's downloadable font families and activates it.
    static func download(_ family: String) async -> Bool {
        await withCheckedContinuation { continuation in
            requestDownload(family) { continuation.resume(returning: $0) }
        }
        && !faces(of: family).isEmpty
    }

    /// Built outside the main actor: Core Text calls the handler on its own queue.
    nonisolated private static func requestDownload(_ family: String, completion: @escaping @Sendable (Bool) -> Void) {
        let once = OnceFlag()
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { state, _ in
            switch state {
            case .didFinish:
                if once.claim() { completion(true) }
            case .didFailWithError:
                if once.claim() { completion(false) }
            default:
                break
            }
            return true
        }
        if !started, once.claim() { completion(false) }
    }
    struct Face: Hashable, Identifiable {
        let postScriptName: String
        let styleName: String
        var id: String { postScriptName }
    }

    static func families() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func faces(of family: String) -> [Face] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member in
            guard let name = member.first as? String, let style = member.dropFirst().first as? String else { return nil }
            return Face(postScriptName: name, styleName: style)
        }
    }

    static func family(of postScriptName: String) -> String {
        NSFont(name: postScriptName, size: 12)?.familyName ?? postScriptName
    }

    static func styleName(of postScriptName: String) -> String {
        let family = family(of: postScriptName)
        return faces(of: family).first { $0.postScriptName == postScriptName }?.styleName ?? "Regular"
    }

    /// Picks the face in `family` closest to the current style (same style name, else Regular).
    static func face(in family: String, matching styleName: String) -> Face? {
        let faces = faces(of: family)
        return faces.first { $0.styleName == styleName }
            ?? faces.first { $0.styleName == "Regular" }
            ?? faces.first
    }

    static func openFontBook() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FontBook") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Lets a callback fire only once even if Core Text reports several end states.
nonisolated private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Font family button with a searchable list (each family shown in its own font),
/// plus a style menu.
struct FontPicker: View {
    let postScriptName: String
    let onChange: (String) -> Void

    @State private var isPresented = false
    @State private var search = ""
    @State private var families: [FontCatalog.Family] = []
    @State private var downloading: String?
    @State private var failed: String?

    private var family: String { FontCatalog.family(of: postScriptName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                InspectorLabel("Font")
                Button {
                    families = FontCatalog.allFamilies()
                    isPresented = true
                } label: {
                    HStack {
                        Text(family)
                            .font(.custom(family, size: 12))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Theme.recessed, in: .rect(cornerRadius: Theme.Metrics.controlCornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius).strokeBorder(Theme.border))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isPresented, arrowEdge: .trailing) { familyList }
            }
            HStack(spacing: 8) {
                InspectorLabel("Style")
                Menu {
                    ForEach(FontCatalog.faces(of: family)) { face in
                        Button(face.styleName) { onChange(face.postScriptName) }
                    }
                } label: {
                    Text(FontCatalog.styleName(of: postScriptName))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
        }
    }

    private var familyList: some View {
        VStack(spacing: 0) {
            TextField("Search fonts", text: $search)
                .themedField()
                .padding(10)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(families.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { entry in
                            Button {
                                choose(entry)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(entry.name)
                                        .font(entry.isInstalled ? .custom(entry.name, size: 14) : .system(size: 13))
                                        .foregroundStyle(entry.name == family ? Theme.accent
                                                         : (entry.isInstalled ? Theme.textPrimary : Theme.textSecondary))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if downloading == entry.name {
                                        ProgressView().controlSize(.mini)
                                    } else if failed == entry.name {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(Theme.destructive)
                                    } else if !entry.isInstalled {
                                        Image(systemName: "icloud.and.arrow.down")
                                            .foregroundStyle(Theme.textTertiary)
                                            .help("Downloads from Apple when chosen")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(downloading != nil)
                            .id(entry.name)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(family, anchor: .center) }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack {
                Text("\(families.filter(\.isInstalled).count) installed · \(families.filter { !$0.isInstalled }.count) downloadable")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Open Font Book…") { FontCatalog.openFontBook() }
                    .controlSize(.small)
            }
            .padding(10)
        }
        .frame(width: 300, height: 420)
        .background(Theme.background)
    }

    private func choose(_ entry: FontCatalog.Family) {
        let style = FontCatalog.styleName(of: postScriptName)
        guard !entry.isInstalled else {
            if let face = FontCatalog.face(in: entry.name, matching: style) { onChange(face.postScriptName) }
            isPresented = false
            return
        }
        downloading = entry.name
        failed = nil
        Task {
            let ok = await FontCatalog.download(entry.name)
            downloading = nil
            guard ok, let face = FontCatalog.face(in: entry.name, matching: style) else {
                failed = entry.name
                return
            }
            onChange(face.postScriptName)
            families = FontCatalog.allFamilies()
            isPresented = false
        }
    }
}
