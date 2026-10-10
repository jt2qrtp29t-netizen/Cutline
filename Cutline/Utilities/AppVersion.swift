import Foundation

/// The app's version from its Info.plist (MARKETING_VERSION / CURRENT_PROJECT_VERSION).
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// e.g. "v1.3"
    static var display: String { "v\(short)" }
}
