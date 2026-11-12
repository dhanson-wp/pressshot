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

    /// Ask while the option is being switched on; without access the notes say why there is
    /// no transcript instead.
    private func requestSpeechRecognitionForAINotes() {
        // Lower the overlay while the system permission dialog is up, so it is clickable.
        let savedLevel = window?.level
        AINotesCoordinator.requestSpeechPermissionIfNeeded(willAsk: { [weak self] in
            self?.window?.level = .normal
        }, didAsk: { [weak self] in
            if let savedLevel { self?.window?.level = savedLevel }
        })
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
