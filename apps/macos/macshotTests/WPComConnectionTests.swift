#if !OFFLINE
import Cocoa
import XCTest

private final class WPComFixture: URLProtocol, @unchecked Sendable {
    nonisolated static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func stopLoading() {}
    nonisolated override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            let (code, headers, data) = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@MainActor
private final class WPComTestCredentials: WordPressCredentialStore {
    var items: [String: WordPressCredential] = [:]
    var failWrites = false
    func read(_ id: String) throws -> WordPressCredential { guard let item = items[id] else { throw WordPressConnectionError.keychain }; return item }
    func write(_ value: WordPressCredential, id: String) throws { if failWrites { throw WordPressConnectionError.keychain }; items[id] = value }
    func remove(_ id: String) throws { items.removeValue(forKey: id) }
}

@MainActor
final class WPComConnectionTests: XCTestCase {
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) -> WPComClient {
        WPComFixture.lock.lock(); WPComFixture.handler = handler; WPComFixture.lock.unlock()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WPComFixture.self]
        return WPComClient(configuration: config)
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func file(ext: String = "mp4") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try Data([0,1,2,3,4,5,6,7,8,9]).write(to: url); return url
    }
    func testApprovalUsesVerifierBoundServiceAndRejectsForgedExpiredOrDuplicateFields() throws {
        let approval = try WPComApproval()
        let url = try approval.authorizationURL(service: URL(string: "https://auth.example")!)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.path, "/start")
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value, approval.challenge)
        XCTAssertFalse(url.absoluteString.contains(approval.verifier))
        XCTAssertFalse(url.absoluteString.contains("client_secret"))
        let valid = "state=\(approval.state)&handoff=synthetic.ticket"
        XCTAssertEqual(try approval.handoff(fragment: valid), "synthetic.ticket")
        for bad in [valid + "&state=other", valid.replacingOccurrences(of: approval.state, with: "forged"), "state=\(approval.state)&access_token=x&token_type=bearer", valid + "#fragment"] {
            XCTAssertThrowsError(try approval.handoff(fragment: bad))
        }
        XCTAssertThrowsError(try approval.handoff(fragment: valid, now: Date().addingTimeInterval(301)))
        XCTAssertThrowsError(try approval.authorizationURL(service: URL(string: "http://auth.example")!))
    }
    func testSitesKeepScreenshotOnlyAndFilterNoUploadPermission() async throws {
        let data = try json(["sites": [
            ["ID": 1, "name": "Images", "URL": "https://images.example", "capabilities": ["upload_files": true], "options": ["videopress_enabled": false]],
            ["ID": 2, "name": "Video", "URL": "https://video.example", "capabilities": ["upload_files": true], "jetpack": true, "jetpack_modules": ["videopress"]],
            ["ID": 3, "name": "Read only", "URL": "https://readonly.example", "capabilities": [], "options": []]
        ]])
        let api = client { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertEqual(request.url?.path, "/rest/v1.1/me/sites")
            return (200, [:], data)
        }
        let sites = try await api.sites(token: "synthetic")
        XCTAssertEqual(sites.map(\.id), [1,2]); XCTAssertFalse(sites[0].hasVideoPress); XCTAssertTrue(sites[1].hasVideoPress)
    }
    func testImageUsesMediaEndpointAndReturnsImageLink() async throws {
        let file = try file(ext: "png"); defer { try? FileManager.default.removeItem(at: file) }
        let data = try json(["id": 42, "source_url": "https://images.example/synthetic.png"])
        let api = client { request in
            XCTAssertEqual(request.url?.path, "/wp/v2/sites/7/media")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            return (200, [:], data)
        }
        let result = try await api.uploadImage(file: file, siteID: 7, token: "synthetic")
        XCTAssertEqual(result.mediaID, 42); XCTAssertNil(result.videoPressGUID)
        XCTAssertEqual(result.link.absoluteString, "https://images.example/synthetic.png")
    }
    func testLibraryLinkComesOnlyFromWhatTheSiteReports() throws {
        // Reference values come from the Library's share-code function.
        XCTAssertEqual(PressShotLibraryLink.code(fileName: "PressShot-AAAA.png"), "3TWVzo32")
        XCTAssertEqual(PressShotLibraryLink.code(fileName: "synthetic.png"), "BMaxxDTW")
        let source = URL(string: "https://images.example/wp-content/uploads/2026/11/PressShot-AAAA.png")!
        XCTAssertEqual(PressShotLibraryLink.screenshot(source: source, reported: "https://library.example")?.absoluteString, "https://library.example/#i/3TWVzo32")
        XCTAssertEqual(PressShotLibraryLink.screenshot(source: source, reported: "https://Library.Example/")?.absoluteString, "https://library.example/#i/3TWVzo32")
        let refused: [Any?] = [nil, NSNull(), 42, "", "http://library.example", "https://user@library.example", "https://library.example:8443",
                               "https://library.example/path", "https://library.example?x=1", "https://library.example/#i/x", "javascript:alert(1)", "library.example"]
        for value in refused { XCTAssertNil(PressShotLibraryLink.screenshot(source: source, reported: value), String(describing: value)) }
    }
    func testUntrustedUploadEndpointNeverReceivesToken() async throws {
        let data = try json(["upload_token": "synthetic", "upload_url": "https://foreign.example/upload"])
        var count = 0
        let api = client { _ in count += 1; return (200, [:], data) }
        do { _ = try await api.videoTicket(siteID: 7, token: "synthetic"); XCTFail("Accepted foreign endpoint") } catch { XCTAssertEqual(error as? WPComError, .invalidResponse) }
        XCTAssertEqual(count, 1)
        for raw in ["http://public-api.wordpress.com/upload", "https://public-api.wordpress.com.evil.example", "https://user@public-api.wordpress.com/upload"] { XCTAssertThrowsError(try WPComClient.validateAPIURL(URL(string: raw)!)) }
    }
    func testVideoChunksResumeAtServerOffsetAndReturnPlayerURL() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file) }
        var patched: [String] = [], retried = false
        let api = client { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.value(forHTTPHeaderField: "X-HTTP-Method-Override") == "HEAD" { return (200, ["Upload-Offset": "4"], Data()) }
            if request.value(forHTTPHeaderField: "X-HTTP-Method-Override") == "PATCH" {
                let offset = request.value(forHTTPHeaderField: "Upload-Offset")!; patched.append(offset)
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-videopress-upload-token"), "session-token")
                if offset == "0", !retried { retried = true; return (503, [:], Data()) }
                let end = Int(offset)! + min(4, 10 - Int(offset)!)
                var headers = ["Upload-Offset": String(end)]
                if end == 10 { headers["x-videopress-upload-guid"] = "abc123"; headers["x-videopress-upload-media-id"] = "42" }
                return (204, headers, Data())
            }
            return (201, ["Location": "/rest/v1.1/video-uploads/7/session", "x-videopress-upload-key-token": "session-token"], Data())
        }
        let result = try await WPComVideoUpload(client: api, chunkSize: 4, retryDelays: [0]).upload(file: file, ticket: .init(endpoint: URL(string: "https://public-api.wordpress.com/rest/v1.1/video-uploads/7")!, token: "ticket"))
        XCTAssertEqual(patched, ["0", "4", "8"])
        XCTAssertEqual(result.link.absoluteString, "https://videopress.com/v/abc123")
    }
    func testLostFinalResponseDoesNotRestartOrInventLink() async throws {
        let file = try file(); defer { try? FileManager.default.removeItem(at: file) }
        var creates = 0
        let api = client { request in
            switch request.value(forHTTPHeaderField: "X-HTTP-Method-Override") {
            case "PATCH": return (503, [:], Data())
            case "HEAD": return (200, ["Upload-Offset": "10"], Data())
            default: creates += 1; return (201, ["Location": "/upload"], Data())
            }
        }
        do { _ = try await WPComVideoUpload(client: api, retryDelays: [0]).upload(file: file, ticket: .init(endpoint: URL(string: "https://public-api.wordpress.com/upload")!, token: "synthetic")); XCTFail("Invented completion") }
        catch { XCTAssertEqual(error as? WPComError, .incompleteUpload) }
        XCTAssertEqual(creates, 1)
    }
    func testSaveFailureDoesNotChangePrimaryAndCorruptEntryDoesNotEraseOtherSites() throws {
        let suite = TestDefaultsSuite.uniqueName("wpcom"), creds = WPComTestCredentials()
        let defaults = UserDefaults(suiteName: suite)!; defer { TestDefaultsSuite.remove(defaults, named: suite) }
        defaults.set("wordpress:existing", forKey: "uploadProvider")
        let store = WPComDestinationsStore(defaults: defaults, credentials: creds)
        let site = WPComSite(id: 7, name: "Images", url: URL(string: "https://images.example")!, canUpload: true, hasVideoPress: false)
        let identity = WPComIdentity(ID: 1, username: "synthetic", display_name: "Synthetic")
        creds.failWrites = true
        XCTAssertThrowsError(try store.save(site: site, identity: identity, grant: .init(token: "synthetic", expires: nil), makePrimary: true))
        XCTAssertTrue(store.destinations.isEmpty); XCTAssertEqual(defaults.string(forKey: "uploadProvider"), "wordpress:existing")
        creds.failWrites = false
        try store.save(site: site, identity: identity, grant: .init(token: "synthetic-secret", expires: nil), makePrimary: false)
        let raw = try XCTUnwrap(defaults.data(forKey: WPComDestinationsStore.key))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("synthetic-secret"))
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [Any]); entries.append(["id":"broken"])
        defaults.set(try json(entries), forKey: WPComDestinationsStore.key)
        XCTAssertEqual(WPComDestinationsStore(defaults: defaults, credentials: creds).destinations.count, 1)
        XCTAssertTrue(SettingsPortability.excludedKeys.contains(WPComDestinationsStore.key))
    }
    func testScreenshotOnlyRecordingDoesNotReadCredentialsOrMakeRequests() async throws {
        let suite = TestDefaultsSuite.uniqueName("wpcom"), creds = WPComTestCredentials()
        let defaults = UserDefaults(suiteName: suite)!; defer { TestDefaultsSuite.remove(defaults, named: suite) }
        let store = WPComDestinationsStore(defaults: defaults, credentials: creds, client: client { _ in XCTFail("Unexpected upload"); return (500, [:], Data()) })
        try store.save(site: .init(id: 7, name: "Images", url: URL(string: "https://images.example")!, canUpload: true, hasVideoPress: false), identity: .init(ID: 1, username: "synthetic", display_name: "Synthetic"), grant: .init(token: "synthetic", expires: nil), makePrimary: true)
        creds.items.removeAll()
        do { _ = try await store.uploadRecording(provider: store.destinations[0].providerID, file: URL(fileURLWithPath: "/missing.mp4")); XCTFail("Unexpected upload") }
        catch { XCTAssertEqual(error as? WPComError, .screenshotOnly) }
    }
    func testScreenshotOnlyPrimaryKeepsRecordingAndNeverUsesSecondary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try file(); defer { try? FileManager.default.removeItem(at: file) }
        let center = PressShotDeliveryCenter(directory: root, recordingTransport: { _, _, _ in XCTFail("Unexpected transfer") }, copyLink: { _ in XCTFail("Unexpected clipboard change") }, recordingRestriction: { _ in "Screenshots only" })
        let id = try XCTUnwrap(center.submitRecording(file: file, selection: .init(primaryID: "wpcom:synthetic", additionalIDs: ["wordpress:other"])))
        await MediaExportCoordinator.shared.waitUntilIdle()
        XCTAssertEqual(center.record(id)?.statuses["wpcom:synthetic"], .unsupported)
        XCTAssertEqual(center.record(id)?.message, "Screenshots only"); XCTAssertFalse(center.record(id)?.isUploading ?? true)
        XCTAssertNotNil(center.fileURL(id)); XCTAssertNil(center.record(id)?.primaryLink)
    }
    func testLoopbackReceivesSyntheticGrantOnceAndRejectsWrongOrigin() async throws {
        let opened = expectation(description: "Callback listener ready")
        let completed = expectation(description: "Grant delivered")
        var state = "", completions = 0
        let auth = WPComAuthorization(browserOpener: { url in
            state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            opened.fulfill(); return true
        }, exchange: { service, ticket, verifier in
            XCTAssertEqual(service.host, "auth.example"); XCTAssertEqual(ticket, "synthetic.ticket"); XCTAssertEqual(verifier.count, 64)
            return WPComGrant(token: "synthetic-loopback", expires: nil)
        })
        defer { auth.cancel() }
        try auth.start(service: URL(string: "https://auth.example")!) { result in
            completions += 1
            if case .success(let grant) = result { XCTAssertEqual(grant.token, "synthetic-loopback") }
            else { XCTFail("Synthetic callback failed") }
            completed.fulfill()
        }
        await fulfillment(of: [opened], timeout: 5)
        let session = URLSession(configuration: .ephemeral)
        let (page, reply) = try await session.data(from: URL(string: WPComApproval.redirect)!)
        XCTAssertEqual((reply as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("history.replaceState"))
        var req = URLRequest(url: URL(string: WPComApproval.redirect + "/" + state)!)
        req.httpMethod = "POST"; req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("state=\(state)&handoff=synthetic.ticket".utf8)
        req.setValue("https://foreign.example", forHTTPHeaderField: "Origin")
        let (_, denied) = try await session.data(for: req)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404); XCTAssertEqual(completions, 0)
        req.setValue("http://127.0.0.1:52632", forHTTPHeaderField: "Origin")
        let (_, accepted) = try await session.data(for: req)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(completions, 1)
    }
    func testCallbackWaitsForExchangeAndReportsFailure() async throws {
        let opened = expectation(description: "Listener ready")
        let completed = expectation(description: "Failure delivered")
        var state = ""
        let auth = WPComAuthorization(browserOpener: { url in
            state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            opened.fulfill(); return true
        }, exchange: { _, _, _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            throw WPComError.network
        })
        defer { auth.cancel() }
        try auth.start(service: URL(string: "https://auth.example")!) { result in
            if case .success = result { XCTFail("Must not report success") }
            completed.fulfill()
        }
        await fulfillment(of: [opened], timeout: 5)
        var request = URLRequest(url: URL(string: WPComApproval.redirect + "/" + state)!)
        request.httpMethod = "POST"
        request.setValue("http://127.0.0.1:52632", forHTTPHeaderField: "Origin")
        request.httpBody = Data("state=\(state)&handoff=synthetic.ticket".utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        await fulfillment(of: [completed], timeout: 5)
    }

    #if DEBUG
    func testNativeConnectionStatesRenderWithCapabilityCopy() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let sheet = WPComConnectionSheet(parent: parent)
        let sites = [WPComSite(id: 7, name: "Weekend Journal", url: URL(string: "https://journal.example")!, canUpload: true, hasVideoPress: false)]
        func labels(_ view: NSView) -> [String] {
            var strings = (view as? NSTextField).map { [$0.stringValue] } ?? []
            if let button = view as? NSButton { strings.append(button.title) }
            return strings + view.subviews.flatMap(labels)
        }
        for (name, stage) in [("choice", WPComConnectionSheet.Stage.choice), ("waiting", .waiting), ("sites", .sites), ("review", .review), ("failure", .failure)] {
            sheet.preview(stage: stage, sites: sites)
            sheet.panel.appearance = NSAppearance(named: .aqua)
            let view = try XCTUnwrap(sheet.panel.contentView); view.layoutSubtreeIfNeeded()
            let copy = labels(view).joined(separator: "\n")
            XCTAssertFalse(copy.contains("Keepsake"))
            if name == "review" { XCTAssertTrue(copy.contains("Recordings: unavailable")); XCTAssertTrue(copy.contains("recordings stay on this Mac")) }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            sheet.panel.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/pressshot-wpcom-" + name + ".png"))
        }
    }
    #endif

}
#endif
