import Foundation

/// Starting a recording with the microphone off asks first, unless someone
/// chose "Don't ask again".
enum MicrophoneOffWarning {
    static let suppressedKey = "suppressMicrophoneOffWarning"

    static func shouldWarn(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: "recordMicAudio") && !defaults.bool(forKey: suppressedKey)
    }
}
