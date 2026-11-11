#if !OFFLINE
import Cocoa

private final class WPComFlippedView: NSView { override var isFlipped: Bool { true } }

/// Approved connection sheet. Credentials stay transient until Save destination.
@MainActor
final class WPComConnectionSheet: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    enum Stage { case choice, waiting, loading, sites, review, failure }
    let panel: NSPanel
    private let parent: NSWindow
    private let content = NSStackView()
    private let actions = NSStackView()
    private let search = NSSearchField()
    private let siteRows = NSStackView()
    private let primary = NSButton(checkboxWithTitle: "Make this my primary destination", target: nil, action: nil)
    private let client: WPComClient
    private let store: WPComDestinationsStore
    private let authorization = WPComAuthorization()
    private var stage = Stage.choice
    private var sites: [WPComSite] = []
    private var selectedID: Int?
    private var identity: WPComIdentity?
    private var grant: WPComGrant?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false
    private var errorText = ""
    private let reconnecting: WPComDestination?
    var onClose: (() -> Void)?
    var onDirectSite: (() -> Void)?
    init(parent: NSWindow, store: WPComDestinationsStore? = nil, reconnecting: WPComDestination? = nil) {
        self.parent = parent; self.store = store ?? .shared; client = self.store.client; self.reconnecting = reconnecting
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "PressShot · Upload destinations"; panel.delegate = self; panel.isReleasedWhenClosed = false
        let root = NSView(); panel.contentView = root
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
        actions.orientation = .horizontal; actions.spacing = 10; actions.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(actions)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28), content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: actions.topAnchor, constant: -20)
        ])
        search.placeholderString = "Search your sites"; search.setAccessibilityLabel("Search your sites"); search.delegate = self
        siteRows.orientation = .vertical; siteRows.alignment = .leading; siteRows.spacing = 8
        primary.state = .on
        render()
    }
    #if DEBUG
    /// In-process rendering with synthetic fixtures only; never opens a browser or saves.
    func preview(stage: Stage, sites: [WPComSite]) {
        self.stage = stage; self.sites = sites; selectedID = sites.first?.id
        identity = .init(ID: 1, username: "synthetic", display_name: "Alex Morgan")
        errorText = stage == .failure ? "Sign-in was cancelled. No destination was added." : ""
        render()
    }
    #endif
    func show() { parent.beginSheet(panel); if reconnecting != nil { signIn() } }
    private func label(_ text: String, heading: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: heading ? 21 : 12, weight: heading ? .semibold : .regular)
        field.preferredMaxLayoutWidth = 552
        return field
    }
    private func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded
        if primary { b.keyEquivalent = "\r" }
        return b
    }
    private func add(_ text: String, heading: Bool = false) { content.addArrangedSubview(label(text, heading: heading)) }
    private func clear(_ stack: NSStackView) { for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() } }
    private var selected: WPComSite? { sites.first { $0.id == selectedID } }
    private func render() {
        clear(content); clear(actions)
        actions.addArrangedSubview(button("Cancel", #selector(close)))
        switch stage {
        case .choice:
            add("Add a destination", heading: true); add("Choose how to connect your WordPress site.")
            content.addArrangedSubview(button("WordPress.com", #selector(signIn), primary: true))
            add("Sign in once, then choose a site. Also supports connected Jetpack sites.")
            content.addArrangedSubview(button("Connect a site directly", #selector(direct)))
            add("Enter a site address and approve access. Keep using the existing connection method.")
        case .waiting:
            add("Continue in your browser", heading: true)
            add("Sign into WordPress.com and approve PressShot, then return here to choose a site.")
            add("Waiting for browser approval…")
            add("PressShot requests account-wide access to list your sites and upload to the destination you choose.")
            content.addArrangedSubview(button("Open browser again", #selector(openBrowser)))
        case .loading:
            add("Loading your sites…", heading: true); add("Checking upload access and VideoPress availability.")
            let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.startAnimation(nil); content.addArrangedSubview(spinner)
        case .sites:
            add(sites.isEmpty ? "No upload destinations found" : "Choose a site", heading: true)
            add("Signed in as " + (identity?.display_name ?? "WordPress.com user"))
            content.addArrangedSubview(button("Switch account", #selector(signIn)))
            if sites.isEmpty {
                add("This account doesn't have upload access to any sites. Try another account or connect a site directly.")
                content.addArrangedSubview(button("Connect a site directly", #selector(direct)))
            } else {
                content.addArrangedSubview(search); search.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
                let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
                let document = WPComFlippedView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
                siteRows.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(siteRows)
                content.addArrangedSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: content.widthAnchor), scroll.heightAnchor.constraint(equalToConstant: 175),
                    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), siteRows.topAnchor.constraint(equalTo: document.topAnchor),
                    siteRows.leadingAnchor.constraint(equalTo: document.leadingAnchor), siteRows.trailingAnchor.constraint(equalTo: document.trailingAnchor), siteRows.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
                renderSites()
                add("Only sites where you can upload media are shown. Sites without VideoPress support screenshots only.")
                let next = button("Continue", #selector(review), primary: true); next.isEnabled = selected != nil; actions.addArrangedSubview(next)
            }
        case .review:
            guard let site = selected else { return }
            add("Connect " + site.name, heading: true); add("WordPress.com · " + (identity?.username ?? ""))
            add("Screenshots: Media Library · image links")
            add(site.hasVideoPress ? "Recordings: VideoPress · player links" : "Recordings: unavailable on this connection")
            content.addArrangedSubview(primary)
            add("Your existing connections stay saved.")
            if !site.hasVideoPress { add("If this is your primary destination, recordings stay on this Mac. Choose a VideoPress-enabled primary to upload them.") }
            else { add("Links follow your site's media and VideoPress access settings.") }
            if !errorText.isEmpty { add(errorText) }
            actions.addArrangedSubview(button("Back", #selector(backToSites)))
            actions.addArrangedSubview(button("Save destination", #selector(save), primary: true))
        case .failure:
            add("Sign-in wasn't completed", heading: true); add(errorText)
            content.addArrangedSubview(button("Connect a site directly", #selector(direct)))
            actions.addArrangedSubview(button("Try again", #selector(signIn), primary: true))
        }
        panel.layoutIfNeeded()
    }
    private func renderSites() {
        clear(siteRows)
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = sites.filter { query.isEmpty || ($0.name + " " + $0.url.absoluteString).localizedCaseInsensitiveContains(query) }
        for site in filtered {
            let b = NSButton(radioButtonWithTitle: site.name + "\n" + (site.url.host ?? "") + " · " + site.capabilityText, target: self, action: #selector(selectSite(_:)))
            b.tag = site.id; b.state = selectedID == site.id ? .on : .off
            b.setAccessibilityLabel(site.name + ", " + site.capabilityText)
            siteRows.addArrangedSubview(b)
        }
        if filtered.isEmpty { siteRows.addArrangedSubview(label("No matching sites. Try another name.")) }
    }
    func controlTextDidChange(_ obj: Notification) { renderSites() }
    @objc private func selectSite(_ sender: NSButton) { selectedID = sender.tag; renderSites(); (actions.arrangedSubviews.last as? NSButton)?.isEnabled = true }
    @objc private func review() { guard selected != nil else { return }; errorText = ""; stage = .review; render() }
    @objc private func backToSites() { stage = .sites; render() }
    @objc private func direct() { let action = onDirectSite; close(); action?() }
    @objc private func openBrowser() { authorization.openBrowser() }
    @objc private func signIn() {
        generation = UUID(); task?.cancel(); authorization.cancel(); grant = nil; identity = nil; sites = []; selectedID = nil; search.stringValue = ""
        guard let service = WPComApproval.configuredService else { fail(WPComError.configuration); return }
        stage = .waiting; render()
        let current = generation
        do {
            try authorization.start(service: service) { [weak self] result in
                guard let self, !self.closed, self.generation == current else { return }
                switch result {
                case .failure(let error): self.fail(error)
                case .success(let grant): self.load(grant, generation: current)
                }
            }
        } catch { fail(error) }
    }
    private func load(_ grant: WPComGrant, generation: UUID) {
        self.grant = grant; stage = .loading; render()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try await client.me(token: grant.token)
                var sites = try await client.sites(token: grant.token)
                try Task.checkCancellation()
                guard !closed, self.generation == generation else { return }
                if let reconnecting {
                    guard identity.ID == reconnecting.accountID else { throw WPComError.permission }
                    sites = sites.filter { $0.id == reconnecting.siteID }
                    guard !sites.isEmpty else { throw WPComError.permission }
                }
                self.identity = identity; self.sites = sites; selectedID = sites.count == 1 ? sites[0].id : nil
                stage = .sites; render()
            } catch { if !closed, self.generation == generation { fail(error) } }
        }
    }
    private func fail(_ error: Error) {
        grant = nil; identity = nil
        errorText = (error as? WPComError)?.localizedDescription ?? "Couldn't reach WordPress.com. Check your connection and try again."
        stage = .failure; render()
    }
    @objc private func save() {
        guard let site = selected, let identity, let grant else { return }
        do { try store.save(site: site, identity: identity, grant: grant, makePrimary: primary.state == .on, reconnecting: reconnecting); close() }
        catch { errorText = (error as? LocalizedError)?.errorDescription ?? "Couldn't save the connection. Try again."; render() }
    }
    @objc private func close() {
        guard !closed else { return }; closed = true; generation = UUID()
        authorization.cancel(); task?.cancel(); grant = nil; identity = nil
        parent.endSheet(panel); panel.orderOut(nil); onClose?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}
#endif
