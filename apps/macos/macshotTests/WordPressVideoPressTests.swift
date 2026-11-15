#if !OFFLINE
import Cocoa
import XCTest

/// One fixture for both the site (Approve-page password) and the VideoPress upload host.
private final class VideoPressFixture: URLProtocol, @unchecked Sendable {
    nonisolated static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func stopLoading() {}
    nonisolated override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            let (code, headers, data) = try XCTUnwrap(handler)(request)
            var all = ["Content-Type": "application/json"]; all.merge(headers) { $1 }
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: all)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@MainActor
private final class VideoPressCredentials: WordPressCredentialStore {
    var items: [String: WordPressCredential] = [:]
    func read(_ id: String) throws -> WordPressCredential { guard let item = items[id] else { throw WordPressConnectionError.keychain }; return item }
    func write(_ value: WordPressCredential, id: String) throws { items[id] = value }
    func remove(_ id: String) throws { items.removeValue(forKey: id) }
}

@MainActor
final class WordPressVideoPressTests: XCTestCase {
    private let site = URL(string: "https://wordpress.example/subsite/")!
    private var discovery: WordPressDiscovery { .init(siteURL: site, apiURL: site.appendingPathComponent("wp-json/"), title: "Synthetic site", authorizationURL: nil) }
    private let credential = WordPressCredential(username: "synthetic", password: "synthetic-application-password")
    private var basic: String { "Basic " + Data("synthetic:synthetic-application-password".utf8).base64EncodedString() }
    private let ticketPath = "/subsite/wp-json/wpcom/v2/videopress/upload-jwt"
    private let uploadURL = "https://public-api.wordpress.com/rest/v1.1/video-uploads/7/"

    private func configuration(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) -> URLSessionConfiguration {
        VideoPressFixture.lock.lock(); VideoPressFixture.handler = handler; VideoPressFixture.lock.unlock()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [VideoPressFixture.self]
        return config
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
    private func recording() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("synthetic video".utf8).write(to: file)
        return file
    }
    private func store(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) throws -> (WordPressDestinationsStore, WordPressDestination, UserDefaults, String) {
        let suite = TestDefaultsSuite.uniqueName("wordpress-videopress")
        let defaults = UserDefaults(suiteName: suite)!
        let config = configuration(handler)
        let store = WordPressDestinationsStore(defaults: defaults, credentials: VideoPressCredentials(),
                                               client: WordPressClient(configuration: config),
                                               videoUpload: WPComVideoUpload(client: WPComClient(configuration: config), chunkSize: 1_000_000, retryDelays: []))
        return (store, try store.save(discovery: discovery, credential: credential, userID: 3), defaults, suite)
    }

    func testVideoPressTicketAsksTheSiteWithTheSamePassword() async throws {
        var requests = 0
        let api = WordPressClient(configuration: configuration { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, self.ticketPath)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), self.basic)
            return (200, [:], try self.json(["upload_token": "site-ticket", "upload_url": self.uploadURL, "upload_blog_id": 7]))
        })
        let answer = await api.videoPressTicket(discovery: discovery, credential: credential)
        let ticket = try XCTUnwrap(answer)
        XCTAssertEqual(ticket.token, "site-ticket")
        XCTAssertEqual(ticket.endpoint.absoluteString, uploadURL)
        XCTAssertEqual(requests, 1)
    }

    func testNoVideoPressTicketWhenTheSiteCantGiveOne() async throws {
        let answers: [(Int, [String: Any])] = [
            (404, ["code": "rest_no_route"]),
            (503, ["code": "owner_not_connected"]),
            (401, ["code": "rest_not_logged_in"]),
            (200, ["upload_token": "", "upload_url": uploadURL]),
            (200, ["upload_token": "site-ticket", "upload_url": "https://uploads.example/rest/v1.1/video-uploads/7/"]),
            (200, ["upload_token": "site-ticket", "upload_url": "http://public-api.wordpress.com/rest/v1.1/video-uploads/7/"]),
        ]
        for (status, body) in answers {
            let api = WordPressClient(configuration: configuration { _ in (status, [:], try self.json(body)) })
            let ticket = await api.videoPressTicket(discovery: discovery, credential: credential)
            XCTAssertNil(ticket, "\(status) \(body)")
        }
    }

    func testRecordingGoesToVideoPressAndRegistersItsAttachment() async throws {
        var paths: [String] = []
        let (store, destination, defaults, suite) = try store { request in
            let override = request.value(forHTTPHeaderField: "X-HTTP-Method-Override")
            paths.append((override ?? request.httpMethod ?? "") + " " + (request.url?.host ?? "") + (request.url?.path ?? ""))
            switch (request.url?.host, request.url?.path, override) {
            case ("wordpress.example", self.ticketPath, nil):
                return (200, [:], try self.json(["upload_token": "site-ticket", "upload_url": self.uploadURL, "upload_blog_id": 7]))
            case ("public-api.wordpress.com", _, nil):
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The site password must never go to the upload host")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-videopress-upload-token"), "site-ticket")
                return (201, ["Location": "/rest/v1.1/video-uploads/7/session", "x-videopress-upload-key-token": "session-token"], Data())
            case ("public-api.wordpress.com", _, "PATCH"):
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (204, ["Upload-Offset": "15", "x-videopress-upload-guid": "abc123", "x-videopress-upload-media-id": "42",
                              "x-videopress-upload-src-url": "https://videos.files.wordpress.com/abc123/synthetic.mp4"], Data())
            case ("wordpress.example", "/subsite/wp-json/pressshot/v1/captures/42/register", nil):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), self.basic)
                XCTAssertEqual(try JSONSerialization.jsonObject(with: self.body(request)) as? [String: String], ["source": "pressshot", "videopressGuid": "abc123"])
                return (200, [:], Data(#"{"id":42,"shareUrl":"https://wordpress.example/s/Vid1"}"#.utf8))
            default:
                XCTFail("Unexpected request \(paths.last ?? "")"); return (500, [:], Data())
            }
        }
        defer { TestDefaultsSuite.remove(defaults, named: suite) }
        let file = try recording(); defer { try? FileManager.default.removeItem(at: file) }
        let delivered = try await store.uploadRecording(provider: destination.providerID, file: file)
        XCTAssertEqual(delivered, .init(link: "https://wordpress.example/s/Vid1"))
        XCTAssertFalse(paths.contains { $0.hasSuffix("/wp/v2/media") }, "A VideoPress recording must not also go to the Media Library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testVideoPressRecordingWithoutPluginCopiesThePlayerLink() async throws {
        let (store, destination, defaults, suite) = try store { request in
            let override = request.value(forHTTPHeaderField: "X-HTTP-Method-Override")
            if request.url?.path == self.ticketPath { return (200, [:], try self.json(["upload_token": "site-ticket", "upload_url": self.uploadURL])) }
            if request.url?.path.hasSuffix("/register") == true { return (404, [:], Data(#"{"code":"rest_no_route"}"#.utf8)) }
            if override == "PATCH" { return (204, ["Upload-Offset": "15", "x-videopress-upload-guid": "abc123", "x-videopress-upload-media-id": "42"], Data()) }
            return (201, ["Location": "/rest/v1.1/video-uploads/7/session"], Data())
        }
        defer { TestDefaultsSuite.remove(defaults, named: suite) }
        let file = try recording(); defer { try? FileManager.default.removeItem(at: file) }
        let delivered = try await store.uploadRecording(provider: destination.providerID, file: file)
        XCTAssertEqual(delivered, .init(link: "https://videopress.com/v/abc123"))
    }

    func testRecordingFallsBackToMediaWhenTheSiteHasNoVideoPress() async throws {
        var paths: [String] = []
        let (store, destination, defaults, suite) = try store { request in
            paths.append(request.url?.path ?? "")
            switch request.url?.path {
            case self.ticketPath: return (404, [:], Data(#"{"code":"rest_no_route"}"#.utf8))
            case "/subsite/wp-json/wp/v2/media":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
                return (201, [:], try self.json(["id": 23, "source_url": "https://wordpress.example/subsite/synthetic.mp4"]))
            case "/subsite/wp-json/pressshot/v1/captures/23/register":
                XCTAssertEqual(try JSONSerialization.jsonObject(with: self.body(request)) as? [String: String], ["source": "pressshot"])
                return (200, [:], Data(#"{"id":23,"shareUrl":"https://wordpress.example/s/Rec1"}"#.utf8))
            default: XCTFail("Unexpected \(request.url?.absoluteString ?? "")"); return (500, [:], Data())
            }
        }
        defer { TestDefaultsSuite.remove(defaults, named: suite) }
        let file = try recording(); defer { try? FileManager.default.removeItem(at: file) }
        let delivered = try await store.uploadRecording(provider: destination.providerID, file: file)
        XCTAssertEqual(delivered, .init(link: "https://wordpress.example/s/Rec1"))
        XCTAssertEqual(paths, [ticketPath, "/subsite/wp-json/wp/v2/media", "/subsite/wp-json/pressshot/v1/captures/23/register"])
    }

    func testScreenshotsNeverAskForAVideoPressTicket() async throws {
        var paths: [String] = []
        let (store, destination, defaults, suite) = try store { request in
            paths.append(request.url?.path ?? "")
            if request.url?.path.hasSuffix("/register") == true { return (200, [:], Data(#"{"id":24,"shareUrl":"https://wordpress.example/s/Img1"}"#.utf8)) }
            return (201, [:], try self.json(["id": 24, "source_url": "https://wordpress.example/subsite/synthetic.png"]))
        }
        defer { TestDefaultsSuite.remove(defaults, named: suite) }
        let image = ImageProbe.makeImage(width: 8, height: 8) { $0.setFillColor(NSColor.red.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let result = await withCheckedContinuation { continuation in
            store.uploadImage(provider: destination.providerID, image: image) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(try result.get(), .init(link: "https://wordpress.example/s/Img1"))
        XCTAssertFalse(paths.contains(ticketPath))
    }
}
#endif
