import Foundation

/// Use one mapping in settings, capture overrides, and completion. Keep explicit
/// local/editor preferences; the connected build defaults to upload after Stop.
enum PressShotRecordingBehavior {
    static var values: [String] {
        #if OFFLINE
        return ["editor", "finder", "clipboard", "save"]
        #else
        return ["upload", "editor", "finder", "clipboard", "save"]
        #endif
    }
    static func value(_ stored: String?) -> String {
        guard let stored, values.contains(stored) else { return values[0] }
        return stored
    }
    static func current(_ defaults: UserDefaults = .standard) -> String {
        value(defaults.string(forKey: "recordingOnStop"))
    }
    static func effective(_ requested: String, isGIF: Bool) -> String {
        // Preserve Record GIF's editable MP4 source. This first automatic
        // WordPress slice delivers MP4/MOV; GIF still opens ready to export.
        isGIF && requested == "upload" ? "editor" : requested
    }
    static func index(_ stored: String?) -> Int { values.firstIndex(of: value(stored)) ?? 0 }
    static var titles: [String] {
        values.map { value in
            switch value {
            case "upload": return L("Upload and copy link")
            case "finder": return L("Show in Finder")
            case "clipboard": return L("Copy to clipboard")
            case "save": return L("Save + copy to clipboard")
            default: return L("Open editor")
            }
        }
    }
}
