import Cocoa
import Security

struct WordPressDestination: Codable, Equatable {
    let id: String
    let siteURL: URL
    let apiURL: URL
    let title: String
    let username: String
    let userID: Int
    var providerID: String { "wordpress:" + id }
    var discovery: WordPressDiscovery { .init(siteURL: siteURL, apiURL: apiURL, title: title, authorizationURL: nil) }
}

@MainActor
protocol WordPressCredentialStore {
    func read(_ id: String) throws -> WordPressCredential
    func write(_ credential: WordPressCredential, id: String) throws
    func remove(_ id: String) throws
}

final class WordPressKeychain: WordPressCredentialStore {
    private let service = "com.derekhanson.pressshot.wordpress"
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    func read(_ id: String) throws -> WordPressCredential {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let credential = try? JSONDecoder().decode(WordPressCredential.self, from: data) else { throw WordPressConnectionError.keychain }
        return credential
    }
    func write(_ credential: WordPressCredential, id: String) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(id); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw WordPressConnectionError.keychain }
        } else if status != errSecSuccess { throw WordPressConnectionError.keychain }
    }
    func remove(_ id: String) throws {
        let result = SecItemDelete(query(id) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw WordPressConnectionError.keychain }
    }
}

@MainActor
final class WordPressDestinationsStore {
    static let shared = WordPressDestinationsStore()
    static let changed = Notification.Name("pressshot.wordpressConnectionsChanged")
    private let defaults: UserDefaults
    private let client: WordPressClient
    #if !OFFLINE
    private let videoUpload: WPComVideoUpload
    #endif
    let credentials: WordPressCredentialStore
    private static let storageKey = "pressshotWordPressDestinations"
    private var key: String { Self.storageKey }
    private(set) var destinations: [WordPressDestination]
    #if !OFFLINE
    init(defaults: UserDefaults = .standard, credentials: WordPressCredentialStore? = nil, client: WordPressClient? = nil, videoUpload: WPComVideoUpload? = nil) {
        self.videoUpload = videoUpload ?? WPComVideoUpload(client: WPComClient())
        self.defaults = defaults; self.credentials = credentials ?? WordPressKeychain(); self.client = client ?? WordPressClient()
        destinations = Self.load(defaults, key: Self.storageKey)
    }
    #else
    init(defaults: UserDefaults = .standard, credentials: WordPressCredentialStore? = nil, client: WordPressClient? = nil) {
        self.defaults = defaults; self.credentials = credentials ?? WordPressKeychain(); self.client = client ?? WordPressClient()
        destinations = Self.load(defaults, key: Self.storageKey)
    }
    #endif
    private static func load(_ defaults: UserDefaults, key: String) -> [WordPressDestination] {
        var destinations = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([WordPressDestination].self, from: $0) } ?? []
        destinations = destinations.filter { UUID(uuidString: $0.id) != nil && (try? WordPressURLRules.validate($0.siteURL)) != nil && (try? WordPressURLRules.validate($0.apiURL)) != nil && WordPressURLRules.sameOrigin($0.siteURL, $0.apiURL) }
        return destinations
    }
    func destination(provider: String) -> WordPressDestination? { destinations.first { $0.providerID == provider } }
    @discardableResult
    func save(discovery: WordPressDiscovery, credential: WordPressCredential, userID: Int) throws -> WordPressDestination {
        try WordPressURLRules.validate(discovery.siteURL); try WordPressURLRules.validate(discovery.apiURL)
        guard userID > 0, WordPressURLRules.sameOrigin(discovery.siteURL, discovery.apiURL) else { throw WordPressConnectionError.response }
        let existing = destinations.first { $0.siteURL == discovery.siteURL && $0.userID == userID }
        let value = WordPressDestination(id: existing?.id ?? UUID().uuidString, siteURL: discovery.siteURL,
            apiURL: discovery.apiURL, title: discovery.title, username: credential.username, userID: userID)
        try credentials.write(credential, id: value.id)
        destinations.removeAll { $0.id == value.id }; destinations.append(value)
        persist()
        return value
    }
    func makePrimary(_ destination: WordPressDestination) {
        guard destinations.contains(destination) else { return }
        defaults.set(destination.providerID, forKey: "uploadProvider"); announce()
    }
    func remove(_ destination: WordPressDestination) throws {
        try credentials.remove(destination.id)
        destinations.removeAll { $0.id == destination.id }
        if defaults.string(forKey: "uploadProvider") == destination.providerID { defaults.removeObject(forKey: "uploadProvider") }
        persist()
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(destinations), forKey: key); announce() }
    private func announce() { NotificationCenter.default.post(name: Self.changed, object: self) }
    static let libraryNote = "File link copied · not added to the Library"
    /// Upload, then register the attachment as a Library shot. Registering never fails the upload:
    /// a site without the plugin keeps the file link quietly; a failed registration keeps it with a note.
    /// Recordings go to VideoPress when the site gives an upload pass, otherwise to Media like screenshots.
    private func deliver(file: URL, mime: String, destination: WordPressDestination, credential: WordPressCredential) async throws -> PressShotDeliveryCenter.Delivered {
        let id: Int, fileLink: URL
        var guid: String?
        #if !OFFLINE
        if mime.hasPrefix("video/"), let ticket = await client.videoPressTicket(discovery: destination.discovery, credential: credential) {
            let upload = try await videoUpload.upload(file: file, ticket: ticket)
            id = upload.mediaID; fileLink = upload.link; guid = upload.videoPressGUID
        } else {
            let upload = try await client.upload(file: file, mime: mime, discovery: destination.discovery, credential: credential)
            id = upload.id; fileLink = upload.fileURL
        }
        #else
        let upload = try await client.upload(file: file, mime: mime, discovery: destination.discovery, credential: credential)
        id = upload.id; fileLink = upload.fileURL
        #endif
        switch await client.register(mediaID: id, videoPressGUID: guid, discovery: destination.discovery, credential: credential) {
        case .shared(let link): return .init(link: link.absoluteString)
        case .noPlugin: return .init(link: fileLink.absoluteString)
        case .failed: return .init(link: fileLink.absoluteString, note: Self.libraryNote)
        }
    }
    func uploadRecording(provider: String, file: URL) async throws -> PressShotDeliveryCenter.Delivered {
        let mime: String
        switch file.pathExtension.lowercased() {
        case "mp4": mime = "video/mp4"
        case "mov": mime = "video/quicktime"
        default: throw WordPressConnectionError.response
        }
        guard let destination = destination(provider: provider) else { throw WordPressConnectionError.response }
        let credential = try credentials.read(destination.id)
        return try await deliver(file: file, mime: mime, destination: destination, credential: credential)
    }
    func uploadImage(provider: String, image: NSImage, completion: @escaping PressShotDeliveryCenter.Completion) {
        guard let destination = destination(provider: provider),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            completion(.failure(WordPressConnectionError.response)); return
        }
        Task {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pressshot_upload_" + UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let credential = try credentials.read(destination.id)
                try data.write(to: file, options: .atomic)
                completion(.success(try await deliver(file: file, mime: "image/png", destination: destination, credential: credential)))
            } catch { completion(.failure(error)) }
        }
    }
}
