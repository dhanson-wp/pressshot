import Cocoa
import XCTest

private final class WordPressFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func stopLoading() {}
    nonisolated override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            let (code, data) = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@MainActor
final class WordPressConnectionTests: XCTestCase {
    private let site = URL(string: "https://wordpress.example/subsite/")!
    private var discovery: WordPressDiscovery { .init(siteURL: site, apiURL: site.appendingPathComponent("wp-json/"), title: "Synthetic site", authorizationURL: site.appendingPathComponent("wp-admin/authorize-application.php")) }
    private let credential = WordPressCredential(username: "synthetic", password: "synthetic-application-password")
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> WordPressClient {
        WordPressFixtureProtocol.lock.lock(); WordPressFixtureProtocol.handler = handler; WordPressFixtureProtocol.lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [WordPressFixtureProtocol.self]
        return WordPressClient(configuration: configuration)
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func callback(_ approval: WordPressApproval, site: String? = nil) -> URL {
        var c = URLComponents(url: approval.callbackURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "site_url", value: site ?? self.site.absoluteString), .init(name: "user_login", value: credential.username), .init(name: "password", value: credential.password)]
        return c.url!
    }
    func testAddressRulesPermitOnlyHTTPSAndExplicitLoopbackHTTP() throws {
        XCTAssertEqual(try WordPressURLRules.site("wordpress.example/blog").absoluteString, "https://wordpress.example/blog/")
        XCTAssertNoThrow(try WordPressURLRules.site("http://localhost:8930"))
        for bad in ["http://wordpress.example", "https://user:password@wordpress.example", "https://wordpress.example/?token=x", "https://wordpress.example/#fragment", "file:///tmp/wordpress", "http://127.0.0.1.example"] { XCTAssertThrowsError(try WordPressURLRules.site(bad), bad) }
    }
    func testCallbackRequiresPendingNonceMatchingSiteAndLifetime() throws {
        let pending = WordPressApproval(discovery: discovery)
        XCTAssertEqual(try pending.credential(from: callback(pending)).username, credential.username)
        XCTAssertThrowsError(try pending.credential(from: callback(pending, site: "https://other.example/")))
        XCTAssertThrowsError(try pending.credential(from: callback(pending), now: Date().addingTimeInterval(601)))
        XCTAssertThrowsError(try pending.credential(from: callback(pending).deletingLastPathComponent()))
        XCTAssertThrowsError(try pending.credential(from: URL(string: callback(pending).absoluteString + "&password=other")!))
    }
    func testApproveAddressIsShortUniqueAndNamesThisMac() throws {
        let a = WordPressApproval(discovery: discovery), b = WordPressApproval(discovery: discovery)
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertEqual(a.nonce.count, 16)
        XCTAssertTrue(a.nonce.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) })
        XCTAssertEqual(a.callbackURL.absoluteString, "pressshot://connect/" + a.nonce)
        let browser = try XCTUnwrap(URLComponents(url: a.browserURL(), resolvingAgainstBaseURL: false))
        let name = try XCTUnwrap(browser.queryItems?.first(where: { $0.name == "app_name" })?.value)
        XCTAssertTrue(name.hasPrefix("PressShot on "))
        XCTAssertLessThanOrEqual(name.count, 73)
    }
    func testWordPressDoubleEncodingAndBrowserCancellation() throws {
        let pending = WordPressApproval(discovery: discovery)
        var c = URLComponents(url: pending.callbackURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "site_url", value: "https%3A%2F%2Fwordpress.example%2Fsubsite%2F"), .init(name: "user_login", value: "user%40example.test"), .init(name: "password", value: "abcd%20efgh")]
        XCTAssertEqual(try pending.credential(from: c.url!).username, "user@example.test")
        XCTAssertEqual(try pending.credential(from: c.url!).password, "abcd efgh")
        c.queryItems = [.init(name: "success", value: "false")]
        XCTAssertThrowsError(try pending.credential(from: c.url!))
        let browser = try XCTUnwrap(URLComponents(url: pending.browserURL(), resolvingAgainstBaseURL: false))
        XCTAssertEqual(browser.queryItems?.first(where: { $0.name == "success_url" })?.value, pending.callbackURL.absoluteString)
    }
    func testDiscoveryDoesNotSendCredentialsAndRejectsForeignAuthorization() async throws {
        let site = self.site
        let body = try json(["url": site.absoluteString, "name": "Synthetic", "namespaces": ["wp/v2"], "routes": ["/wp/v2/media": [:]], "authentication": ["application-passwords": ["endpoints": ["authorization": "https://foreign.example/authorize"]]]])
        let result = try await client { req in
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization")); XCTAssertFalse(req.httpShouldHandleCookies)
            return (200, body)
        }.discover(site.absoluteString)
        XCTAssertNil(result.authorizationURL)
        XCTAssertEqual(result.apiURL, site.appendingPathComponent("wp-json/"))
    }
    func testPlainPermalinkDiscoveryAndVerificationPreserveRestRoute() async throws {
        let site = self.site
        let index = try json(["url": site.absoluteString, "namespaces": ["wp/v2"], "routes": ["/wp/v2/media": [:]]])
        let user = try json(["id": 7, "capabilities": ["upload_files": true]])
        let client = client { req in
            let c = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            if req.url!.path.contains("wp-json") { return (404, Data("{}".utf8)) }
            if c.queryItems?.contains(where: { $0.value == "/wp/v2/users/me" }) == true {
                XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
                XCTAssertTrue(c.queryItems?.contains(where: { $0.name == "context" && $0.value == "edit" }) == true)
                XCTAssertEqual(c.queryItems?.first(where: { $0.name == "_fields" })?.value, "id,capabilities")
                return (200, user)
            }
            return (200, index)
        }
        let discovered = try await client.discover(site.absoluteString)
        let verifiedID = try await client.verify(discovered, credential: credential)
        XCTAssertEqual(verifiedID, 7)
    }
    func testPrivateSiteFallsBackToStandardApprovalOnTheSameSite() async throws {
        let site = self.site
        let privateSite = try json(["code": "private_site", "message": "This site is private.", "data": ["status": 403]])
        let result = try await client { req in
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
            return (403, privateSite)
        }.discover(site.absoluteString)
        XCTAssertEqual(result.siteURL, site)
        XCTAssertEqual(result.apiURL, site.appendingPathComponent("wp-json/"))
        XCTAssertEqual(result.authorizationURL, site.appendingPathComponent("wp-admin/authorize-application.php"))
        let browser = try XCTUnwrap(URLComponents(url: WordPressApproval(discovery: result).browserURL(), resolvingAgainstBaseURL: false))
        XCTAssertEqual(browser.host, site.host)
    }
    func testUnrecognizedForbiddenResponseIsNotTreatedAsWordPress() async throws {
        for body in [Data("<html>Forbidden</html>".utf8), try json(["code": "something_else"])] {
            do { _ = try await client { _ in (403, body) }.discover(site.absoluteString); XCTFail("Non-WordPress 403 accepted") }
            catch { XCTAssertEqual(error as? WordPressConnectionError, .discovery) }
        }
    }
    func testNoUploadCapabilityOrRejectedPasswordFailsVerification() async throws {
        for (code, body) in [(200, try json(["id": 3, "capabilities": ["upload_files": false]])), (401, Data("{}".utf8)), (403, Data("{}".utf8))] {
            do { _ = try await client { _ in (code, body) }.verify(discovery, credential: credential); XCTFail("Unverified account accepted") } catch { XCTAssertTrue(error is WordPressConnectionError) }
        }
    }
    func testUploadSendsFileBodyAndRejectsInvalidReturnedLink() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([137,80,78,71]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let response = try json(["id": 22, "source_url": "javascript:alert(1)"])
        let client = client { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/png")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Disposition")?.hasSuffix(".png\"") == true)
            return (201, response)
        }
        do { _ = try await client.upload(file: file, mime: "image/png", discovery: discovery, credential: credential); XCTFail("Invalid link accepted") } catch { XCTAssertTrue(error is WordPressConnectionError) }
    }
    private final class MemoryCredentials: WordPressCredentialStore {
        var values: [String: WordPressCredential] = [:]
        var failWrites = false
        func read(_ id: String) throws -> WordPressCredential { try XCTUnwrap(values[id]) }
        func write(_ credential: WordPressCredential, id: String) throws { if failWrites { throw WordPressConnectionError.keychain }; values[id] = credential }
        func remove(_ id: String) throws { values[id] = nil }
    }
    func testSavingUsesCredentialStoreAndDoesNotChangePrimary() throws {
        let suite = TestDefaultsSuite.uniqueName("wordpress")
        let defaults = UserDefaults(suiteName: suite)!; defer { TestDefaultsSuite.remove(defaults, named: suite) }
        defaults.set("s3", forKey: "uploadProvider")
        let credentials = MemoryCredentials(), store = WordPressDestinationsStore(defaults: defaults, credentials: credentials)
        let saved = try store.save(discovery: discovery, credential: credential, userID: 3)
        XCTAssertEqual(defaults.string(forKey: "uploadProvider"), "s3")
        XCTAssertFalse(String(data: try XCTUnwrap(defaults.data(forKey: "pressshotWordPressDestinations")), encoding: .utf8)!.contains(credential.password))
        XCTAssertEqual(try credentials.read(saved.id).password, credential.password)
        store.makePrimary(saved); XCTAssertEqual(defaults.string(forKey: "uploadProvider"), saved.providerID)
        let reloaded = WordPressDestinationsStore(defaults: defaults, credentials: credentials)
        XCTAssertEqual(reloaded.destinations, [saved])
        try store.remove(saved); XCTAssertNil(defaults.string(forKey: "uploadProvider")); XCTAssertTrue(credentials.values.isEmpty)
    }
    func testConnectionsAreExcludedFromSettingsBackups() {
        XCTAssertFalse(SettingsPortability.isPortable("pressshotWordPressDestinations"))
    }
    func testFailedKeychainWriteDoesNotSaveDestination() throws {
        let suite = TestDefaultsSuite.uniqueName("wordpress")
        let defaults = UserDefaults(suiteName: suite)!; defer { TestDefaultsSuite.remove(defaults, named: suite) }
        let credentials = MemoryCredentials(); credentials.failWrites = true
        let store = WordPressDestinationsStore(defaults: defaults, credentials: credentials)
        XCTAssertThrowsError(try store.save(discovery: discovery, credential: credential, userID: 3))
        XCTAssertTrue(store.destinations.isEmpty); XCTAssertNil(defaults.data(forKey: "pressshotWordPressDestinations"))
    }
    func testRecordingUploadUsesTheSavedPrimaryCredentialAndMP4Mime() async throws {
        let suite = TestDefaultsSuite.uniqueName("wordpress-recording")
        let defaults = UserDefaults(suiteName: suite)!; defer { TestDefaultsSuite.remove(defaults, named: suite) }
        let response = try json(["id": 23, "source_url": "https://wordpress.example/subsite/synthetic.mp4"])
        var requests = 0
        let api = client { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/subsite/wp-json/wp/v2/media")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("synthetic:synthetic-application-password".utf8).base64EncodedString())
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Disposition")?.hasSuffix(".mp4\"") == true)
            return (201, response)
        }
        let store = WordPressDestinationsStore(defaults: defaults, credentials: MemoryCredentials(), client: api)
        let destination = try store.save(discovery: discovery, credential: credential, userID: 3)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("synthetic video".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let link = try await store.uploadRecording(provider: destination.providerID, file: file)
        XCTAssertEqual(link, "https://wordpress.example/subsite/synthetic.mp4")
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        do { _ = try await store.uploadRecording(provider: "wordpress:missing", file: file); XCTFail("Missing destination accepted") }
        catch { XCTAssertTrue(error is WordPressConnectionError) }
        XCTAssertEqual(requests, 1)
    }

}
