import Cocoa
import Speech

// The AI Notes button in the recording setup toolbar: the toggle, and the
// options behind its right-click menu.
extension OverlayView {

    func toggleAINotes() {
        let enabled = !UserDefaults.standard.bool(forKey: AINotesOptions.enabledKey)
        UserDefaults.standard.set(enabled, forKey: AINotesOptions.enabledKey)
        rebuildToolbarLayout()
        if enabled { requestSpeechRecognitionForAINotes() }
    }

    /// Notes include a transcript of the narration, which needs Speech
    /// Recognition access. Ask while the option is being switched on, never
    /// after a recording stops; without access the notes say so instead.
    private func requestSpeechRecognitionForAINotes() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil,
              SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        // Lower overlay so the system permission dialog is clickable
        let savedLevel = window?.level
        window?.level = .normal
        SFSpeechRecognizer.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async {
                if let saved = savedLevel { self?.window?.level = saved }
            }
        }
    }

    func showAINotesMenu(anchorView: NSView) {
        let menu = NSMenu()
        let controlNames = UserDefaults.standard.object(forKey: AINotesOptions.controlNamesKey) as? Bool ?? true

        let namesItem = NSMenuItem(title: L("Name clicked controls"), action: #selector(toggleAINotesControlNames), keyEquivalent: "")
        namesItem.target = self
        namesItem.state = controlNames ? .on : .off
        menu.addItem(namesItem)

        // What the notes will lack on this Mac, each with the way to add it.
        var missing: [NSMenuItem] = []
        if controlNames, !AINotesElementInspector.isTrusted {
            missing.append(NSMenuItem(title: L("Control names need Accessibility access…"),
                                      action: #selector(requestAccessibilityForAINotes), keyEquivalent: ""))
        }
        if !hasRecordingInputMonitoringPermission {
            missing.append(NSMenuItem(title: L("Typing activity needs Input Monitoring access…"),
                                      action: #selector(requestInputMonitoringForAINotes), keyEquivalent: ""))
        }
        if !missing.isEmpty { menu.addItem(NSMenuItem.separator()) }
        for item in missing {
            item.target = self
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
    }

    @objc private func toggleAINotesControlNames() {
        let current = UserDefaults.standard.object(forKey: AINotesOptions.controlNamesKey) as? Bool ?? true
        UserDefaults.standard.set(!current, forKey: AINotesOptions.controlNamesKey)
    }

    @objc private func requestAccessibilityForAINotes() {
        overlayDelegate?.overlayViewDidRequestAccessibilityPermission()
    }

    @objc private func requestInputMonitoringForAINotes() {
        overlayDelegate?.overlayViewDidRequestInputMonitoringPermission()
    }
}
