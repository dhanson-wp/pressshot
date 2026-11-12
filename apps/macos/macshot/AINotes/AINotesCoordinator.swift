import AppKit

/// Finishes AI notes after a take and gives the rest of the app one place to
/// reach them. Builds run as `MediaExportCoordinator` jobs, so quitting waits
/// for them like any other export; they show no progress window and never
/// hold up delivering the recording.
final class AINotesCoordinator {
    static let shared = AINotesCoordinator()

    /// Reports a build that failed, since nothing else would show it.
    var onFailure: ((String) -> Void)?

    private var gates: [UUID: AINotesNarrationGate] = [:]
    private var quitting = false

    /// Called when a recording produced a file. `quitting` skips transcription so Quit is not kept waiting.
    func finish(_ capture: AINotesCapture, video: URL, quitting: Bool = false) {
        let gate = AINotesNarrationGate()
        if quitting || self.quitting { gate.skip() }
        let id = UUID()
        gates[id] = gate
        MediaExportCoordinator.shared.start(title: "AI notes", status: "Preparing AI notes…", operation: { _, _ in
            try await AINotesBuilder.build(capture, video: video, gate: gate)
        }, completion: { [weak self] result in
            self?.gates[id] = nil
            if case .failure(let error) = result {
                self?.onFailure?(L("AI notes could not be written.") + " " + error.localizedDescription)
            }
        })
    }

    /// The app is quitting: finish the notes in progress without their transcripts.
    func prepareForTermination() {
        quitting = true
        gates.values.forEach { $0.skip() }
    }

    // MARK: Reaching the notes

    /// The newest finished notes, if any take has them.
    var latest: AINotesLibrary.Item? { AINotesLibrary.list().first }

    /// Shows the newest `llm.md` in Finder. Returns false when there are no notes yet.
    @discardableResult
    func revealLatest() -> Bool {
        guard let item = latest else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([item.report])
        return true
    }

    /// Puts the path of the newest `llm.md` on the clipboard, ready to hand to an assistant.
    @discardableResult
    func copyLatestPath() -> Bool {
        guard let item = latest else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.report.path, forType: .string)
        return true
    }

    /// The command that connects Claude Code to this app's notes.
    static var claudeCodeCommand: String {
        let path = Bundle.main.executablePath ?? "/Applications/PressShot.app/Contents/MacOS/PressShot"
        return "claude mcp add pressshot -- \"\(path)\" --mcp"
    }
}
