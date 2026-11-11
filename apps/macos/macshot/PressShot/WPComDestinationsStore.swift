#if !OFFLINE
import Cocoa

struct WPComDestination: Codable, Equatable {
    let id: String
    let siteID: Int
    let siteURL: URL
    var title: String
    let accountID: Int
    var username: String
    var hasVideoPress: Bool
    var tokenExpires: Date?
    var providerID: String { "wpcom:" + id }
    var capabilityText: String { hasVideoPress ? "Screenshots + VideoPress" : "Screenshots only" }
    enum CodingKeys: String, CodingKey { case id, siteID, siteURL, title, accountID, username, hasVideoPress, tokenExpires }
    init(id: String, site: WPComSite, identity: WPComIdentity, expires: Date?) {
        self.id = id; siteID = site.id; siteURL = site.url; title = site.name
        accountID = identity.ID; username = identity.username; hasVideoPress = site.hasVideoPress; tokenExpires = expires
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); siteID = try c.decode(Int.self, forKey: .siteID)
        siteURL = try c.decode(URL.self, forKey: .siteURL); accountID = try c.decode(Int.self, forKey: .accountID)
        guard UUID(uuidString: id) != nil, siteID > 0, accountID > 0, (try? WPComClient.mediaURL(siteURL.absoluteString)) != nil else { throw WPComError.invalidResponse }
        title = (try? c.decode(String.self, forKey: .title)) ?? siteURL.host ?? "WordPress site"
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        hasVideoPress = (try? c.decode(Bool.self, forKey: .hasVideoPress)) ?? false
        tokenExpires = try? c.decode(Date.self, forKey: .tokenExpires)
    }
}

@MainActor
final class WPComDestinationsStore {
    static let shared = WPComDestinationsStore()
    static let key = "pressshotWPComDestinations"
    private let defaults: UserDefaults
    private let credentials: WordPressCredentialStore
    let client: WPComClient
    private(set) var destinations: [WPComDestination]
    init(defaults: UserDefaults = .standard, credentials: WordPressCredentialStore? = nil, client: WPComClient? = nil) {
        self.defaults = defaults; self.credentials = credentials ?? WordPressKeychain(); self.client = client ?? WPComClient()
        // Decode entries independently, so one corrupt destination doesn't discard the rest.
        let entries = defaults.data(forKey: Self.key).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] } ?? []
        var seen = Set<String>()
        destinations = entries.compactMap { entry in
            guard let data = try? JSONSerialization.data(withJSONObject: entry), let d = try? JSONDecoder().decode(WPComDestination.self, from: data), seen.insert(d.id).inserted else { return nil }
            return d
        }
    }
    func destination(provider: String) -> WPComDestination? { destinations.first { $0.providerID == provider } }
    func save(site: WPComSite, identity: WPComIdentity, grant: WPComGrant, makePrimary: Bool, reconnecting: WPComDestination? = nil) throws {
        guard site.id > 0, site.canUpload, identity.ID > 0 else { throw WPComError.permission }
        _ = try WPComClient.mediaURL(site.url.absoluteString)
        if let reconnecting { guard reconnecting.accountID == identity.ID, reconnecting.siteID == site.id else { throw WPComError.permission } }
        let existing = destinations.first { $0.siteID == site.id && $0.accountID == identity.ID }
        let value = WPComDestination(id: existing?.id ?? UUID().uuidString, site: site, identity: identity, expires: grant.expires)
        guard grant.expires.map({ $0 > Date() }) ?? true else { throw WPComError.expired }
        try credentials.write(.init(username: identity.username, password: grant.token), id: value.providerID)
        destinations.removeAll { $0.id == value.id }; destinations.append(value)
        if makePrimary { defaults.set(value.providerID, forKey: "uploadProvider") }
        persist()
    }
    func makePrimary(_ destination: WPComDestination) {
        guard destinations.contains(destination) else { return }
        defaults.set(destination.providerID, forKey: "uploadProvider"); announce()
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(destinations), forKey: Self.key); announce() }
    private func announce() { NotificationCenter.default.post(name: WordPressDestinationsStore.changed, object: nil) }
    private func token(for destination: WPComDestination) throws -> String {
        guard destination.tokenExpires.map({ $0 > Date() }) ?? true else { throw WPComError.expired }
        return try credentials.read(destination.providerID).password
    }
    func uploadRecording(provider: String, file: URL) async throws -> String {
        guard let destination = destination(provider: provider) else { throw WPComError.expired }
        guard destination.hasVideoPress else { throw WPComError.screenshotOnly }
        // VideoPress private grants site members access, not only the owner.
        // Do not create an upstream asset until owner-only ingest is verified.
        throw WPComError.privateVideoUnavailable
    }
    func uploadImage(provider: String, image: NSImage, completion: @escaping PressShotDeliveryCenter.Completion) {
        guard let destination = destination(provider: provider), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { completion(.failure(WPComError.invalidResponse)); return }
        Task {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let token = try token(for: destination)
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let result = try await client.uploadImage(file: file, siteID: destination.siteID, token: token)
                completion(.success(result.link.absoluteString))
            } catch { completion(.failure(error)) }
        }
    }
}
#endif
