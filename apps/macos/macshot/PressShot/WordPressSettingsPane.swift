import Cocoa
import AuthenticationServices

final class WordPressSettingsPane: NSView {
    var showOtherProviders: (() -> Void)?
    private let stack = NSStackView()
    private var connectionSheet: WordPressConnectionSheet?
    #if !OFFLINE
    private var accountSheet: WPComConnectionSheet?
    #endif
    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        addSubview(scroll)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: WordPressDestinationsStore.changed, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func label(_ text: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        view.preferredMaxLayoutWidth = 540
        return view
    }
    private func button(_ title: String, action: Selector, id: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded
        b.identifier = id.map { NSUserInterfaceItemIdentifier($0) }; return b
    }
    @objc private func refresh() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        stack.addArrangedSubview(label("Upload destinations", size: 20, bold: true))
        stack.addArrangedSubview(label("Choose where captures go. Only the successful primary upload copies a link."))
        var hasWordPressDestination = !WordPressDestinationsStore.shared.destinations.isEmpty
        #if !OFFLINE
        hasWordPressDestination = hasWordPressDestination || !WPComDestinationsStore.shared.destinations.isEmpty
        #endif
        if !hasWordPressDestination {
            stack.addArrangedSubview(label("Connect a personal WordPress site to get started. Until you choose a primary destination, captures stay on this Mac."))
        }
        for destination in WordPressDestinationsStore.shared.destinations {
            let text = NSStackView(views: [label(destination.title, size: 13, bold: true), label(destination.siteURL.absoluteString + "\nDirect file links · " + destination.username, size: 11)])
            text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
            let primary = UserDefaults.standard.string(forKey: "uploadProvider") == destination.providerID
            let choose = button(primary ? "Primary" : "Make primary", action: #selector(makePrimary(_:)), id: destination.providerID)
            choose.isEnabled = !primary
            let reconnect = button("Reconnect", action: #selector(reconnect(_:)), id: destination.providerID)
            let row = NSStackView(views: [text, choose, reconnect]); row.spacing = 10; row.alignment = .centerY
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        #if !OFFLINE
        for destination in WPComDestinationsStore.shared.destinations {
            let text = NSStackView(views: [label(destination.title, size: 13, bold: true), label("WordPress.com · " + destination.capabilityText + "\n" + destination.username, size: 11)])
            text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
            let primary = UserDefaults.standard.string(forKey: "uploadProvider") == destination.providerID
            let choose = button(primary ? "Primary" : "Make primary", action: #selector(makePrimary(_:)), id: destination.providerID)
            choose.isEnabled = !primary
            let row = NSStackView(views: [text, choose, button("Reconnect", action: #selector(reconnect(_:)), id: destination.providerID)])
            row.spacing = 10; stack.addArrangedSubview(row)
            if primary && !destination.hasVideoPress { stack.addArrangedSubview(label("Recordings are saved locally while your primary destination is screenshot-only.", size: 11)) }
        }
        #endif
        let add = button("Add destination", action: #selector(addSite))
        add.keyEquivalent = ""; stack.addArrangedSubview(add)
        stack.addArrangedSubview(label("Direct links follow your WordPress site's media-access rules. A PressShot library and revocable share pages aren't connected in this first version.", size: 11))
        let providers = button("Google Drive, imgbb, and S3 settings…", action: #selector(otherProviders))
        stack.addArrangedSubview(providers)
        for destination in PressShotDestinations.available where !destination.id.hasPrefix("wordpress:") && !destination.id.hasPrefix("wpcom:") {
            let primary = UserDefaults.standard.string(forKey: "uploadProvider") == destination.id
            let row = NSStackView(views: [label(destination.title), button(primary ? "Primary" : "Make primary", action: #selector(makePrimary(_:)), id: destination.id)])
            row.spacing = 12; stack.addArrangedSubview(row)
        }
    }
    @objc private func makePrimary(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        #if !OFFLINE
        if let d = WPComDestinationsStore.shared.destination(provider: id) { WPComDestinationsStore.shared.makePrimary(d); return }
        #endif
        if let d = WordPressDestinationsStore.shared.destination(provider: id) { WordPressDestinationsStore.shared.makePrimary(d) }
        else { UserDefaults.standard.set(id, forKey: "uploadProvider"); NotificationCenter.default.post(name: WordPressDestinationsStore.changed, object: nil) }
    }
    @objc private func addSite() {
        #if !OFFLINE
        connectAccount()
        #endif
    }
    #if !OFFLINE
    private func connectAccount(reconnecting: WPComDestination? = nil) {
        guard let window, accountSheet == nil, connectionSheet == nil else { return }
        let sheet = WPComConnectionSheet(parent: window, reconnecting: reconnecting)
        sheet.onClose = { [weak self] in self?.accountSheet = nil }
        sheet.onDirectSite = { [weak self] in self?.connect(site: nil) }
        accountSheet = sheet; sheet.show()
    }
    #endif
    @objc private func reconnect(_ sender: NSButton) {
        #if !OFFLINE
        if let id = sender.identifier?.rawValue, let d = WPComDestinationsStore.shared.destination(provider: id) { connectAccount(reconnecting: d); return }
        #endif
        guard let id = sender.identifier?.rawValue, let d = WordPressDestinationsStore.shared.destination(provider: id) else { return }
        connect(site: d.siteURL.absoluteString)
    }
    private func connect(site: String?) {
        guard let window, connectionSheet == nil else { return }
        let sheet = WordPressConnectionSheet(parent: window, site: site)
        sheet.onClose = { [weak self] in self?.connectionSheet = nil }
        connectionSheet = sheet; sheet.show()
    }
    @objc private func otherProviders() { showOtherProviders?() }
}

/// Only this sheet owns transient browser credentials; they enter Keychain on Save.
final class WordPressConnectionSheet: NSObject, ASWebAuthenticationPresentationContextProviding, NSWindowDelegate {
    private let parent: NSWindow
    private let panel: NSPanel
    private let content = NSStackView()
    private let heading = NSTextField(labelWithString: "Add WordPress site")
    private let note = NSTextField(wrappingLabelWithString: "Enter the site address, approve PressShot in your browser, then return here.")
    private let siteField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let primary = NSButton(title: "Connect", target: nil, action: nil)
    private let fallback = NSButton(title: "Use manual connection instead", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let client = WordPressClient()
    private var authorization: ASWebAuthenticationSession?
    private var approval: WordPressApproval?
    private var task: Task<Void, Never>?
    private var manual = false
    private var verified: (WordPressDiscovery, WordPressCredential, Int)?
    private var closed = false
    var onClose: (() -> Void)?
    init(parent: NSWindow, site: String?) {
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Connect WordPress"; panel.delegate = self; panel.isReleasedWhenClosed = false
        let root = NSView(); panel.contentView = root
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        note.font = .systemFont(ofSize: 12); note.preferredMaxLayoutWidth = 552
        siteField.stringValue = site ?? ""; siteField.placeholderString = "https://your-site.example"
        userField.placeholderString = "WordPress username"; passwordField.placeholderString = "Application password"
        for view in [heading, note] { content.addArrangedSubview(view) }
        let siteLabel = NSTextField(labelWithString: "Site address"); content.addArrangedSubview(siteLabel); content.addArrangedSubview(siteField)
        content.addArrangedSubview(userField); content.addArrangedSubview(passwordField)
        userField.isHidden = true; passwordField.isHidden = true
        userField.setAccessibilityLabel("WordPress username"); passwordField.setAccessibilityLabel("WordPress application password")
        siteField.setAccessibilityLabel("WordPress site address")
        for field in [siteField, userField, passwordField] { field.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        primary.target = self; primary.action = #selector(nextStep); primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        fallback.target = self; fallback.action = #selector(useManual); fallback.bezelStyle = .rounded
        content.addArrangedSubview(fallback)
        cancel.target = self; cancel.action = #selector(close); cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, primary]); buttons.spacing = 15
        buttons.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(buttons)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28), content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28), buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), content.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -18)])
    }
    func show() { parent.beginSheet(panel); panel.makeFirstResponder(siteField) }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { panel }
    @objc private func useManual() {
        manual = true; heading.stringValue = "Connect manually"
        note.stringValue = "Use an application password from your WordPress profile, not your account password."
        userField.isHidden = false; passwordField.isHidden = false; fallback.isHidden = true
        primary.title = "Verify connection"
    }
    private func busy(_ text: String) { note.stringValue = text; primary.isEnabled = false; fallback.isEnabled = false; siteField.isEnabled = false }
    private func failed(_ error: Error) {
        guard !closed else { return }
        note.stringValue = (error as? WordPressConnectionError)?.localizedDescription ?? "We couldn’t reach WordPress. Check the address and try again."
        primary.isEnabled = true; primary.title = verified != nil ? "Save destination" : (manual ? "Verify connection" : "Connect")
        fallback.isEnabled = true; siteField.isEnabled = true
    }
    @objc private func nextStep() {
        if let verified {
            do {
                _ = try WordPressDestinationsStore.shared.save(discovery: verified.0, credential: verified.1, userID: verified.2)
                close()
            } catch { failed(error) }
            return
        }
        let address = siteField.stringValue
        let credential = WordPressCredential(username: userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), password: passwordField.stringValue)
        busy("Finding WordPress at this address…")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let discovery = try await client.discover(address)
                guard !closed else { return }
                if manual { await verify(discovery, credential: credential) }
                else { try startBrowser(discovery) }
            } catch { failed(error) }
        }
    }
    private func startBrowser(_ discovery: WordPressDiscovery) throws {
        let pending = WordPressApproval(discovery: discovery)
        let url = try pending.browserURL(); approval = pending
        busy("Approve PressShot in your browser, then return here. No password needs to be copied.")
        let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "pressshot") { [weak self] callback, error in
            Task { @MainActor [weak self] in
                guard let self, !closed, let pending = approval else { return }
                approval = nil; authorization = nil
                guard error == nil, let callback else { failed(WordPressConnectionError.cancelled); return }
                do { let credential = try pending.credential(from: callback); await verify(pending.discovery, credential: credential) }
                catch { failed(error) }
            }
        }
        auth.presentationContextProvider = self; auth.prefersEphemeralWebBrowserSession = false
        authorization = auth
        if !auth.start() { approval = nil; authorization = nil; throw WordPressConnectionError.browserUnavailable }
    }
    private func verify(_ discovery: WordPressDiscovery, credential: WordPressCredential) async {
        busy("Checking the site and your upload permission. No capture is uploaded during setup…")
        do {
            let userID = try await client.verify(discovery, credential: credential)
            guard !closed else { return }
            verified = (discovery, credential, userID)
            heading.stringValue = "WordPress connection verified"
            note.stringValue = "\(discovery.title)\n\(discovery.siteURL.absoluteString)\n\nUploads allowed. This site uses direct file links, which follow the site's media-access rules. A PressShot library and revocable share pages aren't connected yet.\n\nSave keeps your current primary choice. Choose Make primary in Upload destinations when you’re ready."
            siteField.isHidden = true; userField.isHidden = true; passwordField.stringValue = ""; passwordField.isHidden = true; fallback.isHidden = true
            primary.title = "Save destination"; primary.isEnabled = true
        } catch { failed(error) }
    }
    @objc private func close() {
        guard !closed else { return }; closed = true
        approval = nil; verified = nil; passwordField.stringValue = ""
        task?.cancel(); authorization?.cancel(); authorization = nil
        parent.endSheet(panel); panel.orderOut(nil); onClose?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}
