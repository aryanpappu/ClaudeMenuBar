import Foundation

/// Tiny wrapper around UserDefaults so the user's choices (mute, floating
/// panel, notifications, expanded sections) survive a restart.
enum Prefs {
    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static func set(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
