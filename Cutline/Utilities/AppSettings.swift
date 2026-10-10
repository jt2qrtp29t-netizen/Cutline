import Foundation
import Observation

/// App-wide preferences shared by every editor window.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Universal mute: silences playback in every project.
    var isMuted: Bool = UserDefaults.standard.bool(forKey: "audio.muted") {
        didSet { UserDefaults.standard.set(isMuted, forKey: "audio.muted") }
    }
}
