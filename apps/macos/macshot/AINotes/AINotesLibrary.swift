import Foundation

/// Where AI notes live: inside each take's own folder in the app's data
/// directory, next to the original recording.
///
///     Recordings/<take UUID>/
///       <name>.mp4, session.plist, cursor.mstl, …
///       ai-notes/
///         llm.md          the file an assistant reads first
///         events.json     source of truth; llm.md is rendered from it
///         transcript.vtt  only when there is narration
///         frames/f01-00m00s-start.jpg …
///
/// Notes share the take's lifetime: nothing sweeps them, and deleting the
/// take's folder removes them. Foundation only, so `--mcp` can use it without
/// starting the app.
nonisolated enum AINotesLibrary {
    static let folderName = "ai-notes"
    static let documentName = "events.json"
    static let transcriptName = "transcript.vtt"
    static let framesName = "frames"

    struct Item: Sendable {
        /// The take's `ai-notes` folder.
        var folder: URL
        var document: AINotesDocument

        /// The take's folder name, which is its identifier.
        var takeID: String { folder.deletingLastPathComponent().lastPathComponent }
        var report: URL { folder.appendingPathComponent(AINotesReport.filename) }
    }

    /// The recordings folder, or PRESSSHOT_NOTES_FOLDER for tests and unusual setups.
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["PRESSSHOT_NOTES_FOLDER"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return RecordingSessionStore.rootURL
    }

    static func folder(forTake directory: URL) -> URL {
        directory.appendingPathComponent(folderName, isDirectory: true)
    }

    static func write(_ document: AINotesDocument, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: folder.appendingPathComponent(documentName), options: .atomic)
        try Data(AINotesReport.render(document).utf8).write(to: folder.appendingPathComponent(AINotesReport.filename), options: .atomic)
        let vtt = folder.appendingPathComponent(transcriptName)
        if document.transcript.isEmpty {
            try? FileManager.default.removeItem(at: vtt)
        } else {
            try Data(AINotesReport.vtt(document.transcript).utf8).write(to: vtt, options: .atomic)
        }
    }

    static func read(_ folder: URL) throws -> AINotesDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AINotesDocument.self, from: Data(contentsOf: folder.appendingPathComponent(documentName)))
    }

    /// Takes with finished notes, newest first.
    static func list(in root: URL = AINotesLibrary.root) -> [Item] {
        let takes = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return takes
            .map(folder(forTake:))
            .compactMap { folder in (try? read(folder)).map { Item(folder: folder, document: $0) } }
            .sorted { $0.document.recordedAt > $1.document.recordedAt }
    }
}
