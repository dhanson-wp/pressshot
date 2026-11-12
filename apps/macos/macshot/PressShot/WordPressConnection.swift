import Foundation

struct WordPressCredential: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let username: String
    let password: String
    var description: String { "WordPressCredential(<redacted>)" }
    var debugDescription: String { description }
}

enum WordPressConnectionError: LocalizedError {
    case address, insecureAddress, discovery, browserUnavailable, cancelled, callback, uploadPermission, credentials, response, keychain
    var errorDescription: String? {
        switch self {
        case .address: return "Enter a WordPress site address without a username, password, query, or fragment."
        case .insecureAddress: return "Use an HTTPS site address. HTTP is supported only on localhost for Studio testing."
        case .discovery: return "We couldn’t find a WordPress media API at that address. Check the address and try again."
        case .browserUnavailable: return "Browser approval isn’t available on this site. You can try a manual connection."
        case .cancelled: return "Connection cancelled. No destination was saved."
        case .callback: return "This approval is invalid or expired. Start the connection again."
        case .uploadPermission: return "This WordPress account doesn’t have permission to upload files."
        case .credentials: return "WordPress didn’t accept this connection. Approve again or check the application password."
        case .response: return "WordPress couldn’t complete the request. Your local capture is kept."
        case .keychain: return "PressShot couldn’t access the connection password in Keychain. No unprotected copy was saved."
        }
    }
}

enum WordPressURLRules {
    static func isLoopback(_ host: String) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) }
    static func validate(_ url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.fragment == nil else { throw WordPressConnectionError.address }
        guard c.scheme == "https" || (c.scheme == "http" && isLoopback(host)) else { throw WordPressConnectionError.insecureAddress }
    }
    static func site(_ text: String) throws -> URL {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard var c = URLComponents(string: value), c.query == nil, let url = c.url else { throw WordPressConnectionError.address }
        try validate(url)
        if !c.path.hasSuffix("/") { c.path += "/" }
        guard let normalized = c.url else { throw WordPressConnectionError.address }
        return normalized
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme == b.scheme && a.host?.lowercased() == b.host?.lowercased() && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
}

struct WordPressDiscovery {
    let siteURL: URL
    let apiURL: URL
    let title: String
    let authorizationURL: URL?
    func endpoint(_ path: String) -> URL {
        if var c = URLComponents(url: apiURL, resolvingAgainstBaseURL: false), c.queryItems?.contains(where: { $0.name == "rest_route" }) == true {
            c.queryItems = [.init(name: "rest_route", value: "/" + path)]
            return c.url!
        }
        return apiURL.appendingPathComponent(path)
    }
}

/// One pending approval, bound to a site and an unguessable callback path.
struct WordPressApproval {
    let discovery: WordPressDiscovery
    let nonce: String
    let expires: Date
    init(discovery: WordPressDiscovery, now: Date = Date()) {
        self.discovery = discovery; nonce = Self.makeNonce()
        expires = now.addingTimeInterval(600)
    }
    /// WordPress prints this address on its Approve page, so keep it short:
    /// 16 random characters from a 31-character alphabet (about 79 bits), lowercase and unambiguous.
    static func makeNonce() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet[Int(generator.next(upperBound: UInt32(alphabet.count)))] })
    }
    var callbackURL: URL { URL(string: "pressshot://connect/" + nonce)! }
    /// Shown on the Approve page and in the site's Application passwords list, so
    /// each Mac's password is easy to recognize later.
    static var appName: String {
        let name = (Host.current().localizedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "PressShot on this Mac" }
        return "PressShot on " + String(name.prefix(60))
    }
    func browserURL() throws -> URL {
        guard let url = discovery.authorizationURL, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw WordPressConnectionError.browserUnavailable }
        c.queryItems = (c.queryItems ?? []) + [
            .init(name: "app_name", value: Self.appName),
            .init(name: "app_id", value: "a2e78a3c-71d1-490c-9f52-376bf76d74ee"),
            .init(name: "success_url", value: callbackURL.absoluteString),
            .init(name: "reject_url", value: callbackURL.absoluteString + "?success=false")
        ]
        guard let result = c.url else { throw WordPressConnectionError.callback }
        return result
    }
    func credential(from url: URL, now: Date = Date()) throws -> WordPressCredential {
        guard now <= expires, url.scheme == callbackURL.scheme, url.host == callbackURL.host,
              url.path == callbackURL.path, url.user == nil, url.password == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw WordPressConnectionError.callback }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else { throw WordPressConnectionError.callback }
            values[item.name] = value
        }
        if values["success"] == "false" { throw WordPressConnectionError.cancelled }
        // WordPress urlencode()s these values before adding them to the URL.
        guard let siteText = values["site_url"], let returned = try? WordPressURLRules.site(siteText.removingPercentEncoding ?? siteText),
              returned == discovery.siteURL,
              let encodedUser = values["user_login"], let encodedPassword = values["password"] else { throw WordPressConnectionError.callback }
        let username = encodedUser.removingPercentEncoding ?? encodedUser
        let password = encodedPassword.removingPercentEncoding ?? encodedPassword
        guard !username.isEmpty, !username.contains(":"), !password.isEmpty,
              !username.contains("\n"), !password.contains("\n") else { throw WordPressConnectionError.callback }
        return .init(username: username, password: password)
    }
}

/// No cookies, shared cache, credential persistence, or automatic redirects.
private final class WordPressRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class WordPressClient {
    private let session: URLSession
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 45
        self.session = URLSession(configuration: config, delegate: WordPressRedirectPolicy(), delegateQueue: nil)
    }
    private func request(_ url: URL, credential: WordPressCredential? = nil) throws -> URLRequest {
        try WordPressURLRules.validate(url)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential {
            guard !credential.username.isEmpty, !credential.username.contains(":"), !credential.username.contains("\n"), !credential.password.isEmpty else { throw WordPressConnectionError.credentials }
            request.setValue("Basic " + Data((credential.username + ":" + credential.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        return request
    }
    private func object(_ data: Data, response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw WordPressConnectionError.response }
        if http.statusCode == 401 { throw WordPressConnectionError.credentials }
        if http.statusCode == 403 { throw WordPressConnectionError.uploadPermission }
        guard (200..<300).contains(http.statusCode), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WordPressConnectionError.response }
        return json
    }
    func discover(_ text: String) async throws -> WordPressDiscovery {
        let site = try WordPressURLRules.site(text)
        var plain = URLComponents(url: site, resolvingAgainstBaseURL: false)!
        plain.queryItems = [.init(name: "rest_route", value: "/")]
        var signInRequired = false
        for api in [site.appendingPathComponent("wp-json/"), plain.url!] {
            do {
                let (data, response) = try await session.data(for: request(api))
                if Self.signInRequired(data, response: response) { signInRequired = true; continue }
                let json = try object(data, response: response)
                guard let namespaces = json["namespaces"] as? [String], namespaces.contains("wp/v2"),
                      let routes = json["routes"] as? [String: Any], routes["/wp/v2/media"] != nil,
                      let actualSite = try? WordPressURLRules.site(json["url"] as? String ?? site.absoluteString),
                      WordPressURLRules.sameOrigin(site, actualSite) else { continue }
                let auth = ((json["authentication"] as? [String: Any])?["application-passwords"] as? [String: Any])?["endpoints"] as? [String: Any]
                var authorization: URL?
                if let text = auth?["authorization"] as? String, let candidate = URL(string: text),
                   (try? WordPressURLRules.validate(candidate)) != nil, WordPressURLRules.sameOrigin(site, candidate) { authorization = candidate }
                return .init(siteURL: actualSite, apiURL: api, title: json["name"] as? String ?? actualSite.host!, authorizationURL: authorization)
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        // A private site (WordPress.com private mode, or a plugin that closes the REST index)
        // turns away signed-out requests. Use core's standard addresses on the address the user
        // typed; the signed-in approval and verify() then prove the site and upload permission.
        if signInRequired {
            return .init(siteURL: site, apiURL: site.appendingPathComponent("wp-json/"), title: site.host!,
                         authorizationURL: site.appendingPathComponent("wp-admin/authorize-application.php"))
        }
        throw WordPressConnectionError.discovery
    }
    /// WordPress's own "sign in first" answers, as opposed to a missing or broken API.
    static func signInRequired(_ data: Data, response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, [401, 403].contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String else { return false }
        return ["private_site", "rest_login_required", "rest_not_logged_in", "rest_cannot_access"].contains(code)
    }
    func verify(_ discovery: WordPressDiscovery, credential: WordPressCredential) async throws -> Int {
        var c = URLComponents(url: discovery.endpoint("wp/v2/users/me"), resolvingAgainstBaseURL: false)!
        // Core's additional `capabilities` field doesn't support nested _fields
        // selection on every supported version. Request it whole, then check locally.
        c.queryItems = (c.queryItems ?? []) + [.init(name: "context", value: "edit"), .init(name: "_fields", value: "id,capabilities")]
        let (data, response) = try await session.data(for: request(c.url!, credential: credential))
        let json = try object(data, response: response)
        guard let id = json["id"] as? Int, id > 0,
              (json["capabilities"] as? [String: Any])?["upload_files"] as? Bool == true else { throw WordPressConnectionError.uploadPermission }
        return id
    }
    func upload(file: URL, mime: String, discovery: WordPressDiscovery, credential: WordPressCredential) async throws -> URL {
        let allowed = ["image/png": "png", "image/jpeg": "jpg", "video/mp4": "mp4", "video/quicktime": "mov"]
        guard file.isFileURL, let ext = allowed[mime], (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 }) == true else { throw WordPressConnectionError.response }
        var req = try request(discovery.endpoint("wp/v2/media"), credential: credential)
        req.httpMethod = "POST"
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.setValue("attachment; filename=\"PressShot-\(UUID().uuidString).\(ext)\"", forHTTPHeaderField: "Content-Disposition")
        let (data, response) = try await session.upload(for: req, fromFile: file)
        let json = try object(data, response: response)
        guard let id = json["id"] as? Int, id > 0, let source = json["source_url"] as? String,
              let url = URL(string: source) else { throw WordPressConnectionError.response }
        try WordPressURLRules.validate(url)
        return url
    }
}
