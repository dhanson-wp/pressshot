import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The role and name of the control under a click, read through Accessibility. It only works once
/// the user has granted Accessibility access; until then clicks keep their coordinates and whatever
/// text was recognised under them. The contents of text fields are never read.
nonisolated enum AINotesElementInspector {
    struct Element: Equatable, Sendable {
        var role: String?
        var name: String?
        /// For elements of a web page: a CSS-style handle built from the element's id and classes,
        /// such as `#checkout.btn.btn-primary`. Browsers publish both through Accessibility.
        var selector: String?
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Browsers built on Chromium, which keep the elements of a web page out of Accessibility until asked.
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
    ]

    static func isChromium(_ bundleID: String) -> Bool {
        chromium.contains(bundleID)
    }

    /// Chromium browsers publish the elements of a web page only while an assistive technology
    /// says it is listening, which is what this switch does (it is the one VoiceOver sets). Without
    /// it a click in a page has no name, id or classes. While it is on the browser does a little
    /// more work per page, and window-tiling tools can find its windows slower to move, so it is
    /// set for the length of a recording and put back afterwards.
    /// Returns true when this call turned it on, so the caller knows to turn it off.
    static func exposeWebContent(pid: pid_t) -> Bool {
        guard isTrusted, pid > 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if (app.attribute(enhancedInterface) as? Bool) == true { return false }   // someone else (VoiceOver) owns it
        // Chrome answers "not implemented" and switches anyway, so the result says nothing.
        AXUIElementSetAttributeValue(app, enhancedInterface as CFString, kCFBooleanTrue)
        return true
    }

    static func restoreWebContent(pid: pid_t) {
        guard isTrusted, pid > 0 else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), enhancedInterface as CFString, kCFBooleanFalse)
    }

    private static let enhancedInterface = "AXEnhancedUserInterface"

    /// Puts back what a recording that never reached its end (a crash, a force quit) left switched
    /// on in browsers that are still running. Called once at launch.
    static func restoreAbandonedWebContent(ledger: AINotesBrowserLedger = AINotesBrowserLedger()) {
        let entries = ledger.entries
        guard !entries.isEmpty else { return }
        let running = NSWorkspace.shared.runningApplications.map {
            AINotesBrowserLedger.Entry(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "")
        }
        AINotesBrowserLedger.stillRunning(entries, among: running).forEach { restoreWebContent(pid: $0.pid) }
        ledger.clear()
    }

    /// `point` is in Core Graphics screen space (top-left origin).
    ///
    /// Chromium answers a lookup from what it remembers of the previous one whenever the point
    /// falls inside that element's old bounds, and only then works out the real answer for next
    /// time. After a scroll that names whatever used to be there. `askTwice` asks, waits for the
    /// real answer, and asks again.
    static func element(at point: CGPoint, askTwice: Bool = false) -> Element? {
        guard isTrusted else { return nil }
        // Ask the app that owns the window under the point, as window snapping does; the
        // system-wide element is the fallback for menus and other windows without an owner here.
        let target = ownerPID(at: point).map(AXUIElementCreateApplication) ?? AXUIElementCreateSystemWide()
        // The lookup is a round trip to the app under the pointer; never wait long on a hung app.
        AXUIElementSetMessagingTimeout(target, 0.25)
        var hit: AXUIElement?
        var status = AXUIElementCopyElementAtPosition(target, Float(point.x), Float(point.y), &hit)
        if askTwice {
            Thread.sleep(forTimeInterval: 0.15)
            hit = nil
            status = AXUIElementCopyElementAtPosition(target, Float(point.x), Float(point.y), &hit)
        }
        guard status == .success, let hit else { return nil }

        // The element under the pointer is often a label inside the real control; look a few
        // levels up for something a person would say they clicked.
        var chain: [(role: String?, name: String?, selector: String?)] = []
        var current: AXUIElement? = hit
        var inWebPage = false
        var depth = 0
        while let element = current, depth < 25 {
            let role = string(element, kAXRoleAttribute)
            if role == "AXWindow" || role == "AXApplication" { break }
            if role == "AXWebArea" {
                inWebPage = true
                break
            }
            if chain.count < 5 { chain.append((role, name(of: element, role: role), selector(of: element))) }
            current = parent(of: element)
            depth += 1
        }
        guard let first = chain.first else { return nil }
        let fallbackName = chain.first { $0.name != nil }?.name
        // Outside a web page the same attributes hold the app's own view class names, which mean
        // nothing to someone fixing a site.
        let fallbackSelector = inWebPage ? chain.first { $0.selector != nil }?.selector : nil
        if let control = chain.first(where: { actionable.contains($0.role ?? "") }) {
            return Element(role: friendly(control.role), name: control.name ?? fallbackName,
                           selector: inWebPage ? control.selector ?? fallbackSelector : nil)
        }
        return Element(role: friendly(first.role), name: first.name, selector: inWebPage ? first.selector ?? fallbackSelector : nil)
    }

    /// The field that has the keyboard in an app: its kind and label, never what is in it.
    static func focusedField(pid: pid_t) -> Element? {
        guard isTrusted, pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let value = app.attribute(kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        let role = string(element, kAXRoleAttribute)
        guard typed.contains(role ?? "") else { return nil }
        return Element(role: friendly(role), name: name(of: element, role: role), selector: nil)
    }

    /// The process whose window is frontmost at `point` (Core Graphics space), ours excluded.
    private static func ownerPID(at point: CGPoint) -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), bounds.contains(point) else { continue }
            return pid
        }
        return nil
    }

    private static let actionable: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXTab", "AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox", "AXSearchField",
        "AXSlider", "AXDisclosureTriangle", "AXSwitch",
    ]

    /// Roles whose value is what the user typed. Their value is never read.
    private static let typed: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox", "AXSearchField"]

    private static func name(of element: AXUIElement, role: String?) -> String? {
        var candidates = [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute)]
        if typed.contains(role ?? "") {
            candidates.append(string(element, kAXPlaceholderValueAttribute))
        } else if role == "AXStaticText" || role == "AXLink" || role == "AXHeading" {
            candidates.append(string(element, kAXValueAttribute))
        }
        if let label = element.attribute(kAXTitleUIElementAttribute), CFGetTypeID(label) == AXUIElementGetTypeID() {
            let labelElement = label as! AXUIElement
            candidates.append(string(labelElement, kAXValueAttribute) ?? string(labelElement, kAXTitleAttribute))
        }
        for candidate in candidates {
            let trimmed = candidate?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        return nil
    }

    private static func selector(of element: AXUIElement) -> String? {
        let id = string(element, "AXDOMIdentifier") ?? ""
        let classes = (element.attribute("AXDOMClassList") as? [String] ?? []).filter { !$0.isEmpty }
        guard !id.isEmpty || !classes.isEmpty else { return nil }
        // State classes pile up on some elements; the first few identify it.
        let handle = (id.isEmpty ? "" : "#" + id) + classes.prefix(5).map { "." + $0 }.joined()
        return String(handle.prefix(120))
    }

    private static func friendly(_ role: String?) -> String? {
        guard let role else { return nil }
        switch role {
        case "AXButton", "AXMenuButton": return "button"
        case "AXLink": return "link"
        case "AXTextField", "AXSearchField": return "text field"
        case "AXSecureTextField": return "password field"
        case "AXTextArea": return "text area"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio button"
        case "AXPopUpButton": return "pop-up menu"
        case "AXComboBox": return "combo box"
        case "AXMenuItem": return "menu item"
        case "AXMenuBarItem": return "menu"
        case "AXStaticText": return "text"
        case "AXImage": return "image"
        case "AXTab": return "tab"
        case "AXGroup", "AXUnknown", "AXWebArea", "AXScrollArea": return nil
        default: return role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        element.attribute(attribute) as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = element.attribute(kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

nonisolated private extension AXUIElement {
    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Remembers, across launches, which browsers a recording asked to publish their page elements,
/// so the request can be withdrawn even when the recording never got to withdraw it itself.
nonisolated struct AINotesBrowserLedger: Sendable {
    struct Entry: Equatable, Sendable {
        var pid: pid_t
        var bundleID: String
    }

    static let key = "aiNotesExposedBrowsers"
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var entries: [Entry] {
        (defaults.array(forKey: Self.key) as? [[String: Any]] ?? []).compactMap { item in
            guard let pid = item["pid"] as? Int, let bundleID = item["bundleID"] as? String else { return nil }
            return Entry(pid: pid_t(pid), bundleID: bundleID)
        }
    }

    func add(pid: pid_t, bundleID: String) {
        save(entries.filter { $0.pid != pid } + [Entry(pid: pid, bundleID: bundleID)])
    }

    func remove(pid: pid_t) {
        save(entries.filter { $0.pid != pid })
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private func save(_ entries: [Entry]) {
        guard !entries.isEmpty else { return clear() }
        defaults.set(entries.map { ["pid": Int($0.pid), "bundleID": $0.bundleID] }, forKey: Self.key)
    }

    /// The remembered browsers that are still the same running app. A process id is reused once
    /// its app has quit, so one that now belongs to a different app is left alone.
    static func stillRunning(_ entries: [Entry], among running: [Entry]) -> [Entry] {
        entries.filter { running.contains($0) }
    }
}
