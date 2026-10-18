import Foundation

/// The app's version from its Info.plist (MARKETING_VERSION / CURRENT_PROJECT_VERSION).
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Which edition this is: the Sequoia edition runs on macOS 15 and later, on Intel too.
    static let edition = "Sequoia"

    /// e.g. "v1.3 · Sequoia"
    static var display: String { "v\(short) · \(edition)" }
}
