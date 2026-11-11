#if !OFFLINE
import CryptoKit
import Foundation

// WordPress.com account/media transport. No cookies, redirects, or response bodies in errors.
enum WPComError: LocalizedError, Equatable {
    case privateVideoUnavailable, configuration, cancelled, callback, expired, permission, screenshotOnly, invalidResponse, network, portInUse, incompleteUpload
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .configuration: return "WordPress.com sign-in isn't configured in this build. Connect a site directly for now."
        case .cancelled: return "Sign-in was cancelled or expired. No destination was added."
        case .callback: return "This approval is invalid. Start sign-in again."
        case .expired: return "WordPress.com authorization expired. Reconnect this destination in Settings. Your capture is kept locally."
        case .permission: return "This account can't upload to that site. Check your access or choose another site."
        case .privateVideoUnavailable: return "Private VideoPress uploads aren’t ready yet. Your recording is kept on this Mac. Screenshots still work."
        case .screenshotOnly: return "This destination supports screenshots only. Recording kept on this Mac; choose a VideoPress-enabled primary for future recordings."
        case .invalidResponse: return "WordPress.com returned an unexpected response. Your local capture is kept."
        case .network: return "Couldn't reach WordPress.com. Check your connection and try again."
        case .portInUse: return "The sign-in callback port is unavailable. Close the other sign-in attempt and try again."
        case .incompleteUpload: return "The upload may have finished, but its link wasn't confirmed. Check the site's Media Library before retrying to avoid a duplicate."
        case .http(let status): return "WordPress.com couldn't complete the request (HTTP \(status)). Your local capture is kept."
        }
    }
    var retryable: Bool {
        if case .network = self { return true }
        if case .http(let status) = self { return [408, 409, 423, 429].contains(status) || (500...599).contains(status) }
        return false
    }
}

struct WPComSite: Decodable, Equatable {
    let id: Int
    let name: String
    let url: URL
    let canUpload: Bool
    let hasVideoPress: Bool
    var capabilityText: String { hasVideoPress ? "Screenshots + VideoPress" : "Screenshots only" }
    enum CodingKeys: String, CodingKey { case id = "ID", name, url = "URL", capabilities, options, jetpack, modules = "jetpack_modules" }
    init(id: Int, name: String, url: URL, canUpload: Bool, hasVideoPress: Bool) {
        self.id = id; self.name = name; self.url = url; self.canUpload = canUpload; self.hasVideoPress = hasVideoPress
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id); url = try c.decode(URL.self, forKey: .url)
        name = (try? c.decode(String.self, forKey: .name)) ?? url.host ?? "WordPress site"
        let capabilities = (try? c.decode([String: Bool].self, forKey: .capabilities)) ?? [:]
        canUpload = capabilities["upload_files"] == true
        struct Options: Decodable { let videopress_enabled: Bool? }
        let options = try? c.decode(Options.self, forKey: .options)
        let jetpack = (try? c.decode(Bool.self, forKey: .jetpack)) == true
        let modules = (try? c.decode([String].self, forKey: .modules)) ?? []
        hasVideoPress = options?.videopress_enabled == true || (jetpack && modules.contains("videopress"))
    }
}

struct WPComIdentity: Decodable {
    let ID: Int
    let username: String
    let display_name: String
}

/// Short Library links for screenshots, in place of the long WordPress file address.
/// The app knows no Library of its own. A connected site says which Library it belongs to in the
/// response to an upload ("pressshot_library", set on the site by the PressShot plugin). A site that
/// says nothing keeps getting the WordPress file address.
enum PressShotLibraryLink {
    /// Accepts only a plain https address with a host and nothing else (no sign-in, port, path, or query).
    static func library(_ value: Any?) -> URL? {
        guard let raw = value as? String, raw.count <= 255, let parts = URLComponents(string: raw),
              parts.scheme == "https", let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil,
              host.range(of: "^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$", options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        return URL(string: "https://" + host.lowercased())
    }
    /// Eight letters and digits from the uploaded file's name. Must stay identical to the Library's
    /// own share-code function, or copied links won't open the shot.
    static func code(fileName: String) -> String {
        let letters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return String(SHA256.hash(data: Data(("pressshot-link:" + fileName).utf8)).prefix(8).map { letters[Int($0) % 62] })
    }
    /// `reported` is the raw value the site sent with the upload, or nil.
    static func screenshot(source: URL, reported: Any?) -> URL? {
        let name = source.lastPathComponent
        guard let base = library(reported), !name.isEmpty, name != "/" else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = base.host; parts.path = "/"
        parts.fragment = "i/" + code(fileName: name)
        return parts.url
    }
}

struct WPComUploadResult: Equatable {
    let mediaID: Int
    let sourceURL: URL?
    let videoPressGUID: String?
    let link: URL
}

private final class WPComRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class WPComClient {
    static let base = URL(string: "https://public-api.wordpress.com")!
    private let session: URLSession
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: WPComRedirectPolicy(), delegateQueue: nil)
    }
    static func validateAPIURL(_ url: URL) throws {
        guard url.scheme == "https", url.host == "public-api.wordpress.com", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil else { throw WPComError.invalidResponse }
    }
    static func mediaURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw WPComError.invalidResponse }
        return url
    }
    static func form(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(pairs.map { ($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
    }
    func request(path: String, token: String, method: String = "GET") throws -> URLRequest {
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw WPComError.expired }
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    func send(_ request: URLRequest, file: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw WPComError.invalidResponse }; try Self.validateAPIURL(url)
        do {
            let pair: (Data, URLResponse)
            if let file { pair = try await session.upload(for: request, fromFile: file) }
            else { pair = try await session.data(for: request) }
            guard let response = pair.1 as? HTTPURLResponse else { throw WPComError.invalidResponse }
            switch response.statusCode {
            case 200..<300: return (pair.0, response)
            case 401: throw WPComError.expired
            case 403: throw WPComError.permission
            default: throw WPComError.http(response.statusCode)
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw WPComError.network
        }
    }
    func object(_ data: Data) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WPComError.invalidResponse }
        return result
    }
    func me(token: String) async throws -> WPComIdentity {
        let (data, _) = try await send(request(path: "rest/v1.1/me", token: token))
        guard let me = try? JSONDecoder().decode(WPComIdentity.self, from: data), me.ID > 0 else { throw WPComError.invalidResponse }
        return me
    }
    func sites(token: String) async throws -> [WPComSite] {
        var req = try request(path: "rest/v1.1/me/sites", token: token)
        var url = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "fields", value: "ID,name,URL,capabilities,options,jetpack,jetpack_modules"), .init(name: "options", value: "videopress_enabled,is_wpcom_atomic"), .init(name: "site_visibility", value: "all")]
        req.url = url.url
        let (data, _) = try await send(req)
        guard let values = try object(data)["sites"] as? [[String: Any]] else { throw WPComError.invalidResponse }
        return values.compactMap { value in
            guard let data = try? JSONSerialization.data(withJSONObject: value), let site = try? JSONDecoder().decode(WPComSite.self, from: data),
                  site.id > 0, site.canUpload, (try? Self.mediaURL(site.url.absoluteString)) != nil else { return nil }
            return site
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func uploadImage(file: URL, siteID: Int, token: String) async throws -> WPComUploadResult {
        guard siteID > 0, file.isFileURL, file.pathExtension.lowercased() == "png" else { throw WPComError.invalidResponse }
        let boundary = "PressShot-" + UUID().uuidString
        // Random per-upload name, matching the direct-site and recording paths, so file URLs can't be guessed.
        let filename = "PressShot-\(UUID().uuidString).png"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        try await Task.detached {
            try MultipartBodyWriter.write(to: body) { append in
                try append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: image/png\r\n\r\n".utf8))
                try UploadPayload.file(file).forEachChunk(append)
                try append(Data("\r\n--\(boundary)--\r\n".utf8))
            }
        }.value
        // Core REST through the WordPress.com proxy. Private plugin-enabled sites disable the Jetpack JSON API
        // module, so rest/v1.1/sites/{id}/media/new answers 403 there; wp/v2 only checks site membership.
        var req = try request(path: "wp/v2/sites/\(siteID)/media", token: token, method: "POST")
        req.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(req, file: body)
        let json = try object(data)
        guard let id = json["id"] as? Int, id > 0, let raw = json["source_url"] as? String else { throw WPComError.invalidResponse }
        let url = try Self.mediaURL(raw)
        return .init(mediaID: id, sourceURL: url, videoPressGUID: nil, link: PressShotLibraryLink.screenshot(source: url, reported: json["pressshot_library"]) ?? url)
    }
    struct VideoTicket { let endpoint: URL; let token: String }
    func videoTicket(siteID: Int, token: String) async throws -> VideoTicket {
        let (data, _) = try await send(request(path: "wpcom/v2/sites/\(siteID)/media/videopress-upload-jwt", token: token, method: "POST"))
        let json = try object(data)
        guard let uploadToken = json["upload_token"] as? String, !uploadToken.isEmpty else { throw WPComError.invalidResponse }
        let blogID = json["upload_blog_id"] as? Int ?? siteID
        guard blogID > 0 else { throw WPComError.invalidResponse }
        let endpoint: URL
        if let raw = json["upload_url"] as? String { guard let url = URL(string: raw) else { throw WPComError.invalidResponse }; endpoint = url }
        else { endpoint = Self.base.appendingPathComponent("rest/v1.1/video-uploads/\(blogID)") }
        try Self.validateAPIURL(endpoint)
        return .init(endpoint: endpoint, token: uploadToken)
    }
}
#endif
