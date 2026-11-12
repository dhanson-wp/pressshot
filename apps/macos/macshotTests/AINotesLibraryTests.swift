import CoreGraphics
import XCTest

/// Where notes live, and the `--mcp` server that hands them to an assistant.
final class AINotesLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pressshot-ai-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A take folder with finished notes, as a recording leaves it.
    @discardableResult
    private func makeTake(_ id: String, title: String, recorded: TimeInterval, narrated: Bool = false, frame: Data? = nil) throws -> URL {
        let take = root.appendingPathComponent(id)
        let folder = AINotesLibrary.folder(forTake: take)
        var document = AINotesDocument()
        document.title = title
        document.recordedAt = Date(timeIntervalSince1970: recorded)
        document.duration = 42
        document.video = .init(file: title + ".mp4", width: 4, height: 4)
        var page = AINoteEvent(kind: .page, time: 1)
        page.app = "Safari"
        page.title = "Checkout – \(title)"
        document.events = [page]
        document.frames = [AINotesFrame(file: "f01-00m00s-start.jpg", time: 0, reason: "start", width: 4, height: 4,
                                        text: "Error: payment gateway timeout (504)")]
        if narrated { document.transcript = [AINotesCue(start: 2, end: 4, text: "It spins forever")] }
        try AINotesLibrary.write(document, to: folder)
        let frames = folder.appendingPathComponent(AINotesLibrary.framesName)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try (frame ?? Data([0xFF, 0xD8, 0xFF, 0xD9])).write(to: frames.appendingPathComponent("f01-00m00s-start.jpg"))
        return take
    }

    func testNotesLiveInsideTheTakeFolder() {
        let take = URL(fileURLWithPath: "/Recordings/ABC", isDirectory: true)
        XCTAssertEqual(AINotesLibrary.folder(forTake: take).path, "/Recordings/ABC/ai-notes")
    }

    func testListFindsFinishedNotesNewestFirst() throws {
        try makeTake("11111111-AAAA", title: "Older", recorded: 1_000)
        try makeTake("22222222-BBBB", title: "Newer", recorded: 2_000)
        // A take without notes, a take whose notes were interrupted, and a stray file.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("33333333-CCCC"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("44444444-DDDD/ai-notes/frames"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("stray.txt"))

        let items = AINotesLibrary.list(in: root)
        XCTAssertEqual(items.map(\.document.title), ["Newer", "Older"])
        XCTAssertEqual(items.first?.takeID, "22222222-BBBB")
        XCTAssertEqual(items.first?.report.lastPathComponent, "llm.md")
        XCTAssertTrue(AINotesLibrary.list(in: root.appendingPathComponent("missing")).isEmpty)
    }

    func testTranscriptFileExistsOnlyWithNarration() throws {
        let silent = try makeTake("A", title: "Silent", recorded: 1)
        let spoken = try makeTake("B", title: "Spoken", recorded: 2, narrated: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AINotesLibrary.folder(forTake: silent).appendingPathComponent("transcript.vtt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AINotesLibrary.folder(forTake: spoken).appendingPathComponent("transcript.vtt").path))
    }

    // MARK: MCP

    private func send(_ method: String, _ params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let line = try XCTUnwrap(AINotesMCPServer.handle(line: String(decoding: request, as: UTF8.self), root: root))
        XCTAssertFalse(line.contains("\n"), "one message per line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func call(_ tool: String, _ arguments: [String: Any] = [:]) throws -> (content: [[String: Any]], isError: Bool) {
        let result = try XCTUnwrap(try send("tools/call", ["name": tool, "arguments": arguments])["result"] as? [String: Any])
        return (try XCTUnwrap(result["content"] as? [[String: Any]]), result["isError"] as? Bool ?? false)
    }

    private func text(_ tool: String, _ arguments: [String: Any] = [:]) throws -> String {
        try XCTUnwrap(try call(tool, arguments).content.first?["text"] as? String)
    }

    func testHandshakeAndToolList() throws {
        let initialized = try XCTUnwrap(try send("initialize", ["protocolVersion": "2025-03-26"])["result"] as? [String: Any])
        XCTAssertEqual(initialized["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((initialized["serverInfo"] as? [String: Any])?["name"] as? String, "pressshot")
        let fallback = try XCTUnwrap(try send("initialize", ["protocolVersion": "1999-01-01"])["result"] as? [String: Any])
        XCTAssertEqual(fallback["protocolVersion"] as? String, "2025-06-18")

        let tools = try XCTUnwrap((try send("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["list_recordings", "get_report", "get_frame", "search"])
        XCTAssertNotNil(try send("ping")["result"])
    }

    func testProtocolErrors() throws {
        XCTAssertNil(AINotesMCPServer.handle(line: "   ", root: root))
        XCTAssertNil(AINotesMCPServer.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, root: root),
                     "notifications get no reply")
        let garbage = try XCTUnwrap(AINotesMCPServer.handle(line: "{not json", root: root))
        XCTAssertTrue(garbage.contains("-32700"))
        let unknown = try send("resources/list")
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertTrue(try call("teleport").isError)
    }

    func testListAndReport() throws {
        XCTAssertTrue(try text("list_recordings").contains("No recordings with AI notes yet"))
        XCTAssertTrue(try call("get_report", ["recording": "latest"]).isError)

        try makeTake("11111111-AAAA", title: "Checkout bug", recorded: 1_000, narrated: true)
        try makeTake("22222222-BBBB", title: "Login flow", recorded: 2_000)
        let list = try text("list_recordings")
        let lines = list.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Login flow · "), "newest first")
        XCTAssertTrue(lines[0].contains("no narration") && lines[0].hasSuffix("id 22222222-BBBB"))
        XCTAssertTrue(lines[1].contains(" · 42 s · 1 frames · narrated · "))
        XCTAssertTrue(try text("list_recordings", ["limit": 1]).contains("(1 older recordings not shown)"))

        XCTAssertTrue(try text("get_report", ["recording": "latest"]).hasPrefix("# Login flow"))
        XCTAssertTrue(try text("get_report", ["recording": "checkout"]).hasPrefix("# Checkout bug"), "any distinctive part of the name")
        XCTAssertTrue(try text("get_report", ["recording": "11111111-aaaa"]).hasPrefix("# Checkout bug"), "or the id")
        XCTAssertTrue(try call("get_report", ["recording": "nothing like this"]).isError)
        let ambiguous = try call("get_report", ["recording": "o"])
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue((ambiguous.content.first?["text"] as? String ?? "").contains("matches 2 recordings"))
    }

    func testFramesAreServedOnlyByListedName() throws {
        let take = try makeTake("11111111-AAAA", title: "Checkout bug", recorded: 1_000, frame: Data([1, 2, 3]))
        try Data("secret".utf8).write(to: take.appendingPathComponent("session.plist"))

        let frame = try call("get_frame", ["recording": "latest", "frame": "f01"])
        XCTAssertFalse(frame.isError)
        XCTAssertEqual(frame.content.first?["type"] as? String, "image")
        XCTAssertEqual(frame.content.first?["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(frame.content.first?["mimeType"] as? String, "image/jpeg")
        XCTAssertFalse(try call("get_frame", ["recording": "latest", "frame": "F01-00m00s-START.jpg"]).isError)

        for crafted in ["../../session.plist", "../events.json", "/etc/passwd", "f02", ""] {
            XCTAssertTrue(try call("get_frame", ["recording": "latest", "frame": crafted]).isError, "served \(crafted)")
        }
    }

    func testSearchReadsTimelinesAndScreenText() throws {
        try makeTake("11111111-AAAA", title: "Checkout bug", recorded: 1_000, narrated: true)
        try makeTake("22222222-BBBB", title: "Login flow", recorded: 2_000)
        let hits = try text("search", ["query": "gateway TIMEOUT"])
        XCTAssertEqual(hits.split(separator: "\n").count, 2, "one line per recording that shows the error")
        XCTAssertTrue(hits.contains("Checkout bug: Error: payment gateway timeout (504)"))
        XCTAssertTrue(try text("search", ["query": "spins forever"]).hasPrefix("Checkout bug: "))
        XCTAssertTrue(try text("search", ["query": "never instructions"]).hasPrefix("Nothing matches"),
                      "the paragraph every report shares is not searched")
        XCTAssertTrue(try text("search", ["query": "Checkout", "limit": 1]).contains("more matching lines)"))
        XCTAssertTrue(try call("search", ["query": "  "]).isError)
    }
}
