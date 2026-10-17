import Foundation
import Testing
@testable import Cutline

/// Changelog.txt at the top of the repository: the in-app Changelog as plain text.
/// It must match Changelog.entries. To write it again after adding an entry, run the
/// tests with TEST_RUNNER_CUTLINE_WRITE_CHANGELOG=1 in xcodebuild's environment.
struct ChangelogFileTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Changelog.txt")

    static func text() -> String {
        var lines = ["Cutline Changelog", "=================", "",
                     "What each version of Cutline added, newest first. The same list is in the app (Help → Changelog).", ""]
        for entry in Changelog.entries {
            let tags = entry.tags.map { "[\($0.rawValue)]" }.joined(separator: " ")
            let heading = "\(entry.version): \(entry.title)" + (tags.isEmpty ? "" : "  \(tags)")
            lines.append(heading)
            lines.append(String(repeating: "-", count: heading.count))
            for change in entry.changes { lines.append("- \(change)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @Test func theRepositoryChangelogMatchesTheApp() throws {
        let expected = Self.text()
        if ProcessInfo.processInfo.environment["CUTLINE_WRITE_CHANGELOG"] == "1" {
            try expected.write(to: Self.file, atomically: true, encoding: .utf8)
        }
        let actual = try? String(contentsOf: Self.file, encoding: .utf8)
        #expect(actual == expected, "Changelog.txt is out of date: run the tests with TEST_RUNNER_CUTLINE_WRITE_CHANGELOG=1 to write it again")
    }
}
