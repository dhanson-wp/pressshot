import Foundation

/// `PressShot --mcp` serves finished AI notes to an AI client (Claude Code, Claude Desktop) over
/// stdio, speaking the Model Context Protocol: JSON-RPC 2.0, one message per line. The client
/// launches this process and ends it by closing stdin. There is no network listener and nothing
/// keeps running afterwards. Only stdout carries protocol messages. `main.swift` hands over
/// before the app starts, so nothing here may touch AppKit.
nonisolated enum AINotesMCPServer {
    static let argument = "--mcp"

    private static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func run() -> Never {
        let root = AINotesLibrary.root
        while let line = readLine(strippingNewline: true) {
            guard let response = handle(line: line, root: root) else { continue }
            var data = Data(response.utf8)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }

    /// One request line in, one response line out; nil when the message needs no reply.
    static func handle(line: String, root: URL) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        // Notifications carry no id and get no reply.
        guard let id = message["id"], !(id is NSNull), let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return reply(id, [
                "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "pressshot", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                "instructions": "PressShot screen recordings on this Mac, described as text and still frames. Call list_recordings, then get_report for the one you need. Open a frame with get_frame only when the report's text is not enough.",
            ])
        case "ping":
            return reply(id, [String: Any]())
        case "tools/list":
            return reply(id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return reply(id, ["content": try call(name, arguments, root: root), "isError": false])
            } catch let error as ToolError {
                return reply(id, ["content": [["type": "text", "text": error.message]], "isError": true])
            } catch {
                return reply(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    // MARK: Tools

    private struct ToolError: Error {
        let message: String
    }

    private static let recordingProperty: [String: Any] = [
        "type": "string",
        "description": "A recording's name or id from list_recordings, any distinctive part of the name, or \"latest\".",
    ]

    private static let tools: [[String: Any]] = [
        [
            "name": "list_recordings",
            "description": "List screen recordings that have AI notes, newest first, with date, length and id.",
            "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer", "description": "How many to return (default 20)."]]],
        ],
        [
            "name": "get_report",
            "description": "The written report for one recording: what was said, clicked and shown, with timestamps and the names of its frames.",
            "inputSchema": ["type": "object", "properties": ["recording": recordingProperty], "required": ["recording"]],
        ],
        [
            "name": "get_frame",
            "description": "One still frame of a recording as an image. Use the frame names from the report (for example f03-00m11s-click.jpg, or just f03).",
            "inputSchema": ["type": "object",
                            "properties": ["recording": recordingProperty, "frame": ["type": "string", "description": "Frame file name or its fNN prefix."]],
                            "required": ["recording", "frame"]],
        ],
        [
            "name": "search",
            "description": "Find text across all reports: narration, window titles, clicked controls, and text recognised on screen.",
            "inputSchema": ["type": "object",
                            "properties": ["query": ["type": "string"], "limit": ["type": "integer", "description": "Maximum matching lines (default 40)."]],
                            "required": ["query"]],
        ],
    ]

    /// What a recording is called in tool results: its file name without the extension.
    private static func name(of item: AINotesLibrary.Item) -> String {
        item.document.title.isEmpty ? item.takeID : item.document.title
    }

    private static func find(_ query: String, root: URL) throws -> AINotesLibrary.Item {
        let items = AINotesLibrary.list(in: root)
        guard !items.isEmpty else { throw ToolError(message: "No recordings with AI notes yet.") }
        let needle = query.trimmingCharacters(in: .whitespaces)
        if needle.isEmpty || needle.lowercased() == "latest" { return items[0] }
        if let exact = items.first(where: { name(of: $0) == needle || $0.takeID.caseInsensitiveCompare(needle) == .orderedSame }) { return exact }
        let matches = items.filter { name(of: $0).localizedCaseInsensitiveContains(needle) }
        guard let first = matches.first else { throw ToolError(message: "No recording matches \"\(query)\". Call list_recordings for the names.") }
        guard matches.count == 1 else {
            throw ToolError(message: "\"\(query)\" matches \(matches.count) recordings: \(matches.prefix(8).map(name(of:)).joined(separator: "; ")). Be more specific, or use the id from list_recordings.")
        }
        return first
    }

    private static func text(_ string: String) -> [[String: Any]] {
        [["type": "text", "text": string]]
    }

    private static func call(_ tool: String, _ arguments: [String: Any], root: URL) throws -> [[String: Any]] {
        switch tool {
        case "list_recordings":
            let limit = max(arguments["limit"] as? Int ?? 20, 1)
            let items = AINotesLibrary.list(in: root)
            guard !items.isEmpty else { return text("No recordings with AI notes yet. They are written for recordings made with AI Notes switched on in PressShot's recording toolbar.") }
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.dateFormat = "yyyy-MM-dd HH:mm"
            var lines = items.prefix(limit).map { item -> String in
                let document = item.document
                var parts = [name(of: item)]
                parts.append(date.string(from: document.recordedAt))
                parts.append("\(Int(document.duration.rounded())) s")
                parts.append("\(document.frames.count) frames")
                parts.append(document.transcript.isEmpty ? "no narration" : "narrated")
                parts.append("id \(item.takeID)")
                return parts.joined(separator: " · ")
            }
            if items.count > limit { lines.append("(\(items.count - limit) older recordings not shown)") }
            return text(lines.joined(separator: "\n"))

        case "get_report":
            let item = try find(arguments["recording"] as? String ?? "", root: root)
            guard let report = try? String(contentsOf: item.report, encoding: .utf8) else {
                throw ToolError(message: "The report for \(name(of: item)) could not be read.")
            }
            return text(report)

        case "get_frame":
            let item = try find(arguments["recording"] as? String ?? "", root: root)
            // Only names the notes themselves list are served, so a crafted name cannot reach other files.
            let wanted = URL(fileURLWithPath: arguments["frame"] as? String ?? "").lastPathComponent.lowercased()
            guard !wanted.isEmpty,
                  let frame = item.document.frames.first(where: { $0.file.lowercased() == wanted })
                    ?? item.document.frames.first(where: { $0.file.lowercased().hasPrefix(wanted + "-") }) else {
                throw ToolError(message: "No frame \"\(arguments["frame"] as? String ?? "")\" in \(name(of: item)). Frames: \(item.document.frames.map(\.file).joined(separator: ", "))")
            }
            guard let data = try? Data(contentsOf: item.folder.appendingPathComponent(AINotesLibrary.framesName).appendingPathComponent(frame.file)) else {
                throw ToolError(message: "The frame \(frame.file) is missing from the notes.")
            }
            return [
                ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"],
                ["type": "text", "text": "\(frame.file) at \(AINotesReport.clock(frame.time)) of \(name(of: item))"],
            ]

        case "search":
            let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { throw ToolError(message: "search needs a query.") }
            let limit = max(arguments["limit"] as? Int ?? 40, 1)
            var hits: [String] = []
            var total = 0
            for item in AINotesLibrary.list(in: root) {
                guard let report = try? String(contentsOf: item.report, encoding: .utf8) else { continue }
                // Skip the boilerplate paragraph every report shares.
                let body = report.components(separatedBy: "## Timeline").dropFirst().joined(separator: "## Timeline")
                for line in (report.prefix(while: { $0 != "\n" }) + "\n" + body).split(separator: "\n") where line.localizedCaseInsensitiveContains(query) {
                    total += 1
                    if hits.count < limit {
                        hits.append("\(name(of: item)): \(line.count > 300 ? line.prefix(300) + " …" : line)")
                    }
                }
            }
            guard total > 0 else { return text("Nothing matches \"\(query)\".") }
            if total > hits.count { hits.append("(\(total - hits.count) more matching lines)") }
            return text(hits.joined(separator: "\n"))

        default:
            throw ToolError(message: "Unknown tool \(tool).")
        }
    }

    // MARK: Wire

    private static func reply(_ id: Any, _ result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(_ message: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
