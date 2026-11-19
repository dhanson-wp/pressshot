#if !OFFLINE
import Cocoa
import CryptoKit
import Network
import Security

/// Cloudup uploads. Each upload is its own stream, so a link never leads to other captures.
/// Links are unlisted: anyone with the link can open it, and nobody can find it otherwise.
///
/// This is the rebuilt Cloudup's API: sign in through the browser (OAuth authorization code
/// with PKCE and a loopback redirect), then POST /streams, POST /items (which answers with a
/// presigned storage address), PUT the file there, and PATCH the item complete.
final class CloudupUploader {
    static let shared = CloudupUploader()
    static let changed = Notification.Name("pressshot.cloudupChanged")
    static let providerID = "cloudup"

    /// Where Cloudup lives and how PressShot identifies itself to it.
    struct Configuration: Equatable {
        var api: URL
        var auth: URL
        var clientID: String
        var clientSecret: String

        /// Cloudup registers this address for the PressShot app, so it can't change here alone.
        /// Cloudup matches the host and path; the port is ours to listen on.
        static let redirectURI = "http://127.0.0.1:52634/callback"
        static let callbackPort: UInt16 = 52634

        /// The build's Cloudup app, or nil when it has none. In Debug builds, `PRESSSHOT_CLOUDUP_*`
        /// environment variables point a development run at another Cloudup server and its own app.
        /// Release builds ignore them, so nothing outside the app can redirect sign-in or uploads.
        static var bundled: Configuration? {
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            #else
            let environment: [String: String] = [:]
            #endif
            func value(_ variable: String, _ infoKey: String) -> String {
                let text = environment[variable] ?? Bundle.main.object(forInfoDictionaryKey: infoKey) as? String ?? ""
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let clientID = value("PRESSSHOT_CLOUDUP_CLIENT_ID", "PressShotCloudupClientID")
            let clientSecret = value("PRESSSHOT_CLOUDUP_CLIENT_SECRET", "PressShotCloudupClientSecret")
            guard !clientID.isEmpty, !clientSecret.isEmpty else { return nil }
            let api = URL(string: environment["PRESSSHOT_CLOUDUP_API"] ?? "") ?? URL(string: "https://api.cloudup.com")!
            let auth = URL(string: environment["PRESSSHOT_CLOUDUP_AUTH"] ?? "") ?? Self.authServer(for: api)
            return Configuration(api: api, auth: auth, clientID: clientID, clientSecret: clientSecret)
        }

        /// api.cloudup.com signs in at auth.cloudup.com: the sign-in server is the API host's
        /// `auth.` sibling. Any other host signs in where its API is.
        static func authServer(for api: URL) -> URL {
            guard var components = URLComponents(url: api, resolvingAgainstBaseURL: false),
                  let host = components.host, host.hasPrefix("api.") else { return api }
            components.host = "auth." + host.dropFirst("api.".count)
            components.path = ""
            return components.url ?? api
        }
    }

    private let configuration: Configuration?
    private let session: URLSession
    private let tokenFileOverride: URL?
    private let defaults: UserDefaults
    private let retryDelay: UInt64
    private var authGeneration = UUID()
    private var tokenRefresh: (id: UUID, task: Task<String, Error>)?
    private var loopback: CloudupLoopback?

    init(configuration: Configuration? = Configuration.bundled, session: URLSession? = nil, tokenFileURL: URL? = nil,
         defaults: UserDefaults = .standard, retryDelayNanoseconds: UInt64 = 2_000_000_000) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        self.configuration = configuration
        self.session = session ?? URLSession(configuration: config)
        self.tokenFileOverride = tokenFileURL
        self.defaults = defaults
        self.retryDelay = retryDelayNanoseconds
    }

    /// This build carries a Cloudup app, so signing in can be offered.
    var isConfigured: Bool { configuration != nil }
    var isSignedIn: Bool { configuration != nil && loadTokens().refreshToken != nil }
    var username: String? { defaults.string(forKey: "cloudupUsername") }

    // MARK: - Sign-in

    /// Opens the browser to sign in to Cloudup and finishes with the account's username.
    func signIn(openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
                completion: @escaping (Result<String, Error>) -> Void) {
        guard let configuration else { completion(.failure(Self.error("This build has no Cloudup app, so sign-in is unavailable."))); return }
        authGeneration = UUID()
        let generation = authGeneration
        loopback?.cancel()
        tokenRefresh?.task.cancel()
        tokenRefresh = nil
        let verifier = Self.randomURLSafe(bytes: 48)
        let state = Self.randomURLSafe(bytes: 32)
        let url = Self.authorizationURL(configuration: configuration, state: state, challenge: Self.challenge(for: verifier))
        Task { [weak self] in
            guard let self else { return }
            do {
                try await requireRebuiltCloudup(configuration)
                try checkAccount(generation)
                let listener = CloudupLoopback(port: Configuration.callbackPort, state: state)
                loopback = listener
                let code = try await listener.waitForCode { if !openBrowser(url) { listener.cancel() } }
                try checkAccount(generation)
                loopback = nil
                let json = try await jsonResponse(tokenRequest(configuration, ["grant_type": "authorization_code", "code": code,
                                                                              "code_verifier": verifier, "redirect_uri": Configuration.redirectURI]))
                try checkAccount(generation)
                let access = try saveTokens(from: json, keeping: nil)
                let name = try await fetchUsername(configuration, accessToken: access)
                try checkAccount(generation)
                defaults.set(name, forKey: "cloudupUsername")
                // Bring Settings back in front of the browser. There is no application when run headless.
                NSApp?.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: Self.changed, object: nil)
                completion(.success(name))
            } catch {
                if generation == authGeneration { loopback = nil }
                completion(.failure(error))
            }
        }
    }

    func signOut() {
        authGeneration = UUID()
        loopback?.cancel()
        loopback = nil
        tokenRefresh?.task.cancel()
        tokenRefresh = nil
        try? FileManager.default.removeItem(at: tokenFileURL)
        defaults.removeObject(forKey: "cloudupUsername")
        if defaults.string(forKey: "uploadProvider") == Self.providerID { defaults.removeObject(forKey: "uploadProvider") }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static func authorizationURL(configuration: Configuration, state: String, challenge: String) -> URL {
        var components = URLComponents(url: configuration.auth.appendingPathComponent("auth"), resolvingAgainstBaseURL: false)!
        // No scope: Cloudup then grants what the registered app is allowed.
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: Configuration.redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The S256 challenge for a verifier (RFC 7636).
    static func challenge(for verifier: String) -> String {
        urlSafe(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return urlSafe(Data(buffer))
    }

    private static func urlSafe(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The rebuilt Cloudup answers an unauthenticated request with an OAuth error object. The
    /// service it replaces doesn't, and has no sign-in server for this flow, so say so up front
    /// instead of opening a browser page that can't work.
    private func requireRebuiltCloudup(_ configuration: Configuration) async throws {
        var request = URLRequest(url: configuration.api.appendingPathComponent("users"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard Self.isRebuiltCloudup(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data) else {
            throw Self.error("Cloudup's new sign-in isn't available at \(configuration.api.host ?? "this address") yet.")
        }
    }

    /// Presigned upload addresses must be HTTPS. Debug builds also accept a local mock server.
    static func allowsStorage(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        #if DEBUG
        return url.host == "127.0.0.1"
        #else
        return false
        #endif
    }

    static func isRebuiltCloudup(status: Int, body: Data) -> Bool {
        guard status == 401, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return json["error"] as? String == "access_denied"
    }

    private func fetchUsername(_ configuration: Configuration, accessToken: String) async throws -> String {
        var request = URLRequest(url: configuration.api.appendingPathComponent("users"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let json = try await jsonResponse(request)
        return json["username"] as? String ?? json["name"] as? String ?? json["email"] as? String ?? "Cloudup"
    }

    // MARK: - Upload

    func upload(payload: UploadPayload, filename: String, mimeType: String,
                progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                completion: @escaping (Result<String, Error>) -> Void) {
        let generation = authGeneration
        UploadJob.start(filename: filename, operation: { [weak self] in
            guard let self else { throw CancellationError() }
            guard let configuration else { throw Self.error("This build has no Cloudup app.") }
            let body = try await MediaExportIO.perform { try PreparedUploadBody(payload: payload) }
            try checkAccount(generation)
            return try await uploadFile(configuration, body: body, filename: filename, mimeType: mimeType,
                                        generation: generation, progress: progress)
        }, completion: completion)
    }

    func uploadImage(_ image: NSImage, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let pixels = try HistoryImageSnapshot.Image(image)
            let template = defaults.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
            upload(payload: .image(pixels), filename: FilenameFormatter.format(template: template) + ".png",
                   mimeType: "image/png", progress: progress, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func uploadVideo(url: URL, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        let mimeTypes = ["gif": "image/gif", "mov": "video/quicktime"]
        upload(payload: .file(url), filename: url.lastPathComponent,
               mimeType: mimeTypes[url.pathExtension.lowercased()] ?? "video/mp4",
               progress: progress, completion: completion)
    }

    // A response from before sign-out can neither restore credentials nor finish an upload
    // into another account.
    private func checkAccount(_ generation: UUID) throws {
        guard generation == authGeneration else { throw Self.error("Account changed during upload") }
    }

    private func uploadFile(_ configuration: Configuration, body: PreparedUploadBody, filename: String, mimeType: String,
                            generation: UUID, progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> String {
        let title = (filename as NSString).deletingPathExtension
        let stream = try await api(configuration, "POST", "streams", ["title": title], generation: generation)
        guard let streamID = stream["id"] as? String, !streamID.isEmpty else { throw Self.error("Cloudup created a stream without an ID") }
        do {
            let item = try await api(configuration, "POST", "items", [
                "filename": filename, "mime": mimeType, "size": body.byteCount, "stream_id": streamID, "title": title,
            ], generation: generation)
            guard let itemID = item["id"] as? String, !itemID.isEmpty,
                  let storage = (item["s3_url"] as? String).flatMap(URL.init(string:)), Self.allowsStorage(storage) else {
                throw Self.error("Cloudup didn't say where to upload the file")
            }
            try await put(body, to: storage, mimeType: mimeType, generation: generation, progress: progress)
            let done = try await api(configuration, "PATCH", "items/\(itemID)", ["complete": true], generation: generation)
            guard let link = done["url"] as? String ?? item["url"] as? String, URL(string: link)?.host != nil else {
                throw Self.error("Cloudup finished the upload without a link")
            }
            return link
        } catch {
            // Don't leave an empty stream behind.
            if generation == authGeneration { _ = try? await api(configuration, "DELETE", "streams/\(streamID)", nil, generation: generation) }
            throw error
        }
    }

    /// The address is presigned for this object alone and carries its own authorization.
    /// Storage refuses x-amz-* headers that weren't signed, so only the type and length go along.
    /// Sending the same bytes to the same address again is harmless, so transient failures retry.
    private func put(_ body: PreparedUploadBody, to storage: URL, mimeType: String, generation: UUID,
                     progress: (@MainActor @Sendable (Double) -> Void)?) async throws {
        for attempt in 1...3 {
            try checkAccount(generation)
            var request = URLRequest(url: storage)
            request.httpMethod = "PUT"
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
            do {
                let (data, response) = try await UploadTransport.upload(session: session, request: request, body: body, progress: progress)
                if (200...299).contains(response.statusCode) { return }
                if (500...599).contains(response.statusCode), attempt < 3 {
                    try await Task.sleep(nanoseconds: retryDelay * UInt64(attempt)); continue
                }
                let detail = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Self.error("Cloudup's storage refused the file (HTTP \(response.statusCode))" + (detail.isEmpty || detail.hasPrefix("<") ? "" : ": \(detail)"))
            } catch let error as URLError where attempt < 3 && [.networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code) {
                try await Task.sleep(nanoseconds: retryDelay * UInt64(attempt))
            }
        }
        throw Self.error("Upload could not be completed")
    }

    /// A Bearer-authenticated JSON call. A refused token is renewed once and the call repeated.
    private func api(_ configuration: Configuration, _ method: String, _ path: String, _ body: [String: Any]?,
                     generation: UUID) async throws -> [String: Any] {
        for attempt in 1...2 {
            try checkAccount(generation)
            var request = URLRequest(url: configuration.api.appendingPathComponent(path))
            request.httpMethod = method
            request.setValue("Bearer \(try await validToken(forceRefresh: attempt > 1))", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            try checkAccount(generation)
            let (data, response) = try await session.data(for: request)
            try checkAccount(generation)
            guard let response = response as? HTTPURLResponse else { throw Self.error("No response from Cloudup") }
            if response.statusCode == 401, attempt == 1 { continue }
            return try Self.parseResponse(data, response: response)
        }
        throw Self.error("Cloudup no longer accepts the saved sign-in. Sign in again in Settings.")
    }

    // MARK: - Tokens

    private func tokenRequest(_ configuration: Configuration, _ values: [String: String]) -> URLRequest {
        var request = URLRequest(url: configuration.auth.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var fields = values
        fields["client_id"] = configuration.clientID
        fields["client_secret"] = configuration.clientSecret
        request.httpBody = UploadTransport.formBody(fields)
        return request
    }

    /// Cloudup replaces the refresh token each time it is used, so every caller shares one
    /// renewal: two in parallel would sign the account out.
    private func validToken(forceRefresh: Bool = false) async throws -> String {
        let generation = authGeneration
        let tokens = loadTokens()
        if !forceRefresh, let expiry = tokens.expiry, Date().timeIntervalSince1970 < expiry, let token = tokens.accessToken { return token }
        if let pending = tokenRefresh { return try await pending.task.value }
        guard let configuration, let refresh = tokens.refreshToken else { throw Self.error("Not signed in to Cloudup") }
        let id = UUID()
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let json = try await jsonResponse(tokenRequest(configuration, ["grant_type": "refresh_token", "refresh_token": refresh]))
            try checkAccount(generation)
            return try saveTokens(from: json, keeping: refresh)
        }
        tokenRefresh = (id, task)
        defer { if tokenRefresh?.id == id { tokenRefresh = nil } }
        return try await task.value
    }

    private struct TokenData: Codable {
        var accessToken: String?
        var refreshToken: String?
        var expiry: Double?
    }

    /// Stores a token response and returns its access token.
    private func saveTokens(from json: [String: Any], keeping refresh: String?) throws -> String {
        guard let access = json["access_token"] as? String, !access.isEmpty,
              let refresh = json["refresh_token"] as? String ?? refresh else { throw Self.error("Invalid sign-in response from Cloudup") }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let tokens = TokenData(accessToken: access, refreshToken: refresh, expiry: Date().timeIntervalSince1970 + lifetime - 60)
        let data = try JSONEncoder().encode(tokens)
        try data.write(to: tokenFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
        return access
    }

    // File-based like the Google Drive tokens, which avoids Keychain prompts after each update.
    private var tokenFileURL: URL {
        if let tokenFileOverride { return tokenFileOverride }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.derekhanson.pressshot")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return dir.appendingPathComponent("cloudup_tokens.json")
    }

    private func loadTokens() -> TokenData {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let tokens = try? JSONDecoder().decode(TokenData.self, from: data) else { return TokenData() }
        return tokens
    }

    // MARK: - Helpers

    private func jsonResponse(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Self.error("No response from Cloudup") }
        return try Self.parseResponse(data, response: response)
    }

    private static func parseResponse(_ data: Data, response: HTTPURLResponse) throws -> [String: Any] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200...299).contains(response.statusCode) else {
            let message = json?["error_description"] as? String ?? json?["message"] as? String ?? json?["error"] as? String ?? "Invalid server response"
            throw error("\(message) (HTTP \(response.statusCode))")
        }
        return json ?? [:]
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "CloudupUploader", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Catches Cloudup's sign-in redirect once on 127.0.0.1, answers the browser, and stops.
/// Only a request to /callback carrying this attempt's state can finish it.
final class CloudupLoopback {
    private let port: UInt16
    private let state: String
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?

    init(port: UInt16, state: String) {
        self.port = port
        self.state = state
    }

    /// Starts listening, calls `ready` once the port is open, and returns the sign-in code.
    func waitForCode(timeoutSeconds: UInt64 = 300, ready: @escaping () -> Void) async throws -> String {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var announced = false
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.continuation != nil else { return }
                    switch state {
                    case .ready: if !announced { announced = true; ready() }
                    case .failed: self.finish(.failure(Self.error("Port \(self.port) is in use, so the Cloudup sign-in can't be received. Quit whatever holds it and try again.")))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, self.continuation != nil, self.connections.count < 16 else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    self.receive(connection, buffer: Data())
                }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000) } catch { return }
                self?.finish(.failure(Self.error("Timed out waiting for the browser. Try signing in again.")))
            }
        }
    }

    func cancel() { finish(.failure(Self.error("Sign-in was cancelled."))) }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        // Open connections finish sending their page before they close themselves.
        continuation.resume(with: result)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] bytes, _, ended, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var data = buffer
                if let bytes { data.append(bytes) }
                guard data.count <= 32768 else { self.close(connection); return }
                if let split = data.range(of: Data("\r\n\r\n".utf8)) {
                    self.handle(connection, head: String(decoding: data[..<split.lowerBound], as: UTF8.self))
                } else if ended || error != nil {
                    self.close(connection)
                } else {
                    self.receive(connection, buffer: data)
                }
            }
        }
    }

    private func handle(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard parts.count == 3, parts[0] == "GET", host == "127.0.0.1:\(port)",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"), components.path == "/callback" else {
            respond(connection, status: 404, title: "Not found", text: "This address only finishes a Cloudup sign-in.")
            return
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
        // A request without this attempt's state didn't come from our sign-in; leave it pending.
        guard continuation != nil, values["state"] == state else {
            respond(connection, status: 400, title: "Sign-in expired", text: "Start a new Cloudup sign-in in PressShot.")
            return
        }
        if let code = values["code"], !code.isEmpty {
            respond(connection, status: 200, title: "Signed in to Cloudup", text: "You can close this window and return to PressShot.")
            finish(.success(code))
        } else {
            respond(connection, status: 200, title: "Sign-in cancelled", text: "You can close this window and try again from PressShot.")
            finish(.failure(Self.error(values["error"] == "access_denied" ? "Sign-in was cancelled in the browser."
                                       : "Cloudup sign-in failed: \(values["error_description"] ?? values["error"] ?? "no code returned")")))
        }
    }

    private func respond(_ connection: NWConnection, status: Int, title: String, text: String) {
        let html = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>PressShot</title><style>body{font:16px/1.5 -apple-system,sans-serif;margin:3rem auto;max-width:28rem;text-align:center;color:#222b3a}h1{font-weight:600}</style></head><body><h1>\(title)</h1><p>\(text)</p></body></html>"
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + html).utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.close(connection) }
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "CloudupUploader", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
