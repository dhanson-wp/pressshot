import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Speech

/// On-device text recognition for the kept frames, through the app's shared `VisionOCR`.
nonisolated enum AINotesFrameText {
    struct Line: Equatable, Sendable {
        /// Already redacted: text that looked like a secret never leaves this type.
        var text: String
        /// Fractions of the frame, origin at its top-left corner.
        var box: CGRect
        /// The part of the frame that held something redacted, to black out in the picture.
        var secret: CGRect?
    }

    /// Icons and decorations come back as low-confidence guesses; they are noise, not text.
    static let minimumConfidence: Float = 0.45

    /// nil when recognition failed (as opposed to finding nothing). `ignoringTop` leaves out a
    /// strip at the top of the frame, as a fraction of its height: the menu bar, whose status
    /// icons read as gibberish.
    static func recognize(imageAt url: URL, ignoringTop: Double = 0) async -> [Line]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return await withCheckedContinuation { continuation in
            VisionOCR.performTextRecognition(cgImage: image) { observations, error in
                if error != nil, observations.isEmpty {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: lines(from: observations, ignoringTop: ignoringTop))
                }
            }
        }
    }

    static func lines(from observations: [OCRTextObservation], ignoringTop: Double = 0) -> [Line] {
        observations.compactMap { observation in
            guard observation.confidence >= minimumConfidence else { return nil }
            let original = observation.text
            // Vision's boxes have their origin at the bottom-left.
            let box = flipped(observation.boundingBox)
            guard original.trimmingCharacters(in: .whitespaces).count > 1, box.midY >= ignoringTop else { return nil }
            let redacted = AINotesRedactor.redact(original, valuesRunToEndOfLine: true)
            var secret: CGRect?
            if let span = AINotesRedactor.changedSpan(original: original, redacted: redacted) {
                let from = original.index(original.startIndex, offsetBy: span.lowerBound)
                let to = original.index(original.startIndex, offsetBy: span.upperBound)
                // The recogniser knows where those characters are; fall back to even character widths.
                if from < to, let exact = observation.boundingBox(for: from..<to), exact.width > 0, exact.height > 0 {
                    secret = flipped(exact).insetBy(dx: -0.004, dy: -0.002)
                } else {
                    secret = estimatedPart(of: box, span: span, count: original.count)
                }
            }
            return Line(text: redacted.trimmingCharacters(in: .whitespaces), box: box, secret: secret)
        }
    }

    private static func flipped(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// The part of a line's box that holds characters `span`, assuming even character widths.
    static func estimatedPart(of box: CGRect, span: Range<Int>, count: Int) -> CGRect {
        let total = CGFloat(max(count, 1))
        // Letters are not evenly wide, so cover a character and a half more on each side.
        let pad = max(1.5 / total, 0.02)
        let from = max(CGFloat(span.lowerBound) / total - pad, 0), to = min(CGFloat(span.upperBound) / total + pad, 1)
        return CGRect(x: box.minX + box.width * from, y: box.minY, width: box.width * max(to - from, 0.05), height: box.height)
    }

    /// The recognised line under `point` (a fraction of the frame from its top-left), or the
    /// closest one within reach. This is how a click gets a name without Accessibility access.
    /// `sameRow` is true when the text is only level with the click, some way to its side: the
    /// usual case for a click on an arrow or icon at the end of a row.
    static func line(at point: CGPoint, in lines: [Line]) -> (text: String, sameRow: Bool)? {
        if let near = nearLine(at: point, in: lines) { return (near, false) }
        let row = lines.filter { $0.box.minY - 0.004 <= point.y && point.y <= $0.box.maxY + 0.004 }
            .map { ($0, max($0.box.minX - point.x, 0, point.x - $0.box.maxX)) }
            .min { $0.1 < $1.1 }
        if let row, row.1 < 0.5 { return (row.0.text, true) }
        return nil
    }

    private static func nearLine(at point: CGPoint, in lines: [Line]) -> String? {
        if let hit = lines.filter({ $0.box.insetBy(dx: -0.006, dy: -0.008).contains(point) })
            .min(by: { $0.box.width * $0.box.height < $1.box.width * $1.box.height }) {
            return hit.text
        }
        let nearest = lines.map { line -> (Line, CGFloat) in
            let dx = max(line.box.minX - point.x, 0, point.x - line.box.maxX)
            let dy = max(line.box.minY - point.y, 0, point.y - line.box.maxY)
            return (line, (dx * dx + dy * dy).squareRoot())
        }.min { $0.1 < $1.1 }
        if let nearest, nearest.1 < 0.03 { return nearest.0.text }
        return nil
    }
}

/// Reads frames while the recording is still running, one at a time at low priority, so that
/// little is left to do when it stops. It also absorbs the wait macOS can impose on the first
/// text request from a new build of an app.
nonisolated final class AINotesFrameReader: @unchecked Sendable {
    private let ignoringTop: Double
    private let lock = NSLock()
    private var waiting: [URL] = []
    private var results: [URL: [AINotesFrameText.Line]] = [:]
    private var running = false
    private var stopped = false

    init(ignoringTop: Double) {
        self.ignoringTop = ignoringTop
    }

    /// A frame was just written to `url`.
    func enqueue(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        waiting.append(url)
        guard !running else { return }
        running = true
        Task.detached(priority: .utility) { [self] in
            while let next = takeNext() {
                // A frame dropped by the budget is gone by now; skip it.
                guard FileManager.default.fileExists(atPath: next.path) else { continue }
                if let lines = await AINotesFrameText.recognize(imageAt: next, ignoringTop: ignoringTop) {
                    keep(lines, for: next)
                }
            }
        }
    }

    private func keep(_ lines: [AINotesFrameText.Line], for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        if !stopped { results[url] = lines }
    }

    private func takeNext() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !waiting.isEmpty else {
            running = false
            return nil
        }
        return waiting.removeFirst()
    }

    /// Stops reading and returns what was finished, by the path each frame had when it was read.
    /// Anything still in flight is left for the pass after the recording.
    func stop() -> [URL: [AINotesFrameText.Line]] {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        waiting = []
        return results
    }
}

/// Lets quitting cut the slow part of a build (transcription) short without losing the notes.
nonisolated final class AINotesNarrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var skipped = false
    private var task: Task<[CaptionTimeline.Word], Error>?

    var isSkipped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return skipped
    }

    func skip() {
        lock.lock()
        skipped = true
        let running = task
        lock.unlock()
        running?.cancel()
    }

    fileprivate func track(_ task: Task<[CaptionTimeline.Word], Error>) {
        lock.lock()
        self.task = task
        let cancelNow = skipped
        lock.unlock()
        if cancelNow { task.cancel() }
    }
}

/// Turns what a recording gathered into finished notes: reads the frames, redacts, marks clicks,
/// transcribes the narration, and writes `llm.md`, `events.json` and `transcript.vtt`.
nonisolated enum AINotesBuilder {
    static var generator: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "PressShot \(version) (\(build))"
    }

    /// Runs after the video is saved. A failure removes the half-made notes and never touches the take.
    @discardableResult
    static func build(_ capture: AINotesCapture, video: URL, gate: AINotesNarrationGate = AINotesNarrationGate()) async throws -> URL {
        do {
            let (narration, cues) = await narrate(video: video, microphone: capture.microphone, gate: gate)
            let lines = await recognizeFrames(of: capture)
            let duration = (try? await AVURLAsset(url: video).load(.duration).seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            // Re-encoding frames and writing files is kept off the caller's actor (the main one).
            return try await MediaExportIO.perform {
                let document = assemble(capture, video: video, lines: lines, narration: narration, cues: cues, duration: duration)
                try AINotesLibrary.write(document, to: capture.folder)
                return capture.folder
            }
        } catch {
            capture.discard()
            throw error
        }
    }

    // MARK: Frames

    /// The text of each frame, by file name: what was read during the recording, and now the rest.
    private static func recognizeFrames(of capture: AINotesCapture) async -> [String: [AINotesFrameText.Line]] {
        let directory = capture.folder.appendingPathComponent(AINotesLibrary.framesName)
        var lines = capture.recognized
        var failures = 0
        // Recognition that keeps failing will not start working mid-build; stop waiting on it.
        for frame in capture.frames where lines[frame.file] == nil && failures < 2 {
            let found = await AINotesFrameText.recognize(imageAt: directory.appendingPathComponent(frame.file),
                                                         ignoringTop: capture.menuBarFraction)
            lines[frame.file] = found
            failures = found == nil ? failures + 1 : 0
        }
        return lines
    }

    /// Finishes the frames on disk (covers what was redacted, draws the click rings) and puts the
    /// document together. `lines` is the recognised text of each frame, by file name.
    static func assemble(_ capture: AINotesCapture, video: URL, lines: [String: [AINotesFrameText.Line]],
                         narration: AINotesDocument.Narration, cues: [AINotesCue], duration: Double?) -> AINotesDocument {
        let directory = capture.folder.appendingPathComponent(AINotesLibrary.framesName)
        var frames = capture.frames
        for index in frames.indices {
            let file = frames[index].file
            let found = lines[file]
            frames[index].text = found.map { $0.map(\.text).joined(separator: "\n") }
            // Only now, after reading: cover what was redacted, and draw the ring where it could
            // not hide the clicked label from recognition.
            AINotesFrameEncoder.finish(frameAt: directory.appendingPathComponent(file), ring: capture.rings[file],
                                       covering: (found ?? []).compactMap(\.secret))
        }

        // Without Accessibility a click has no name; the text under it is the next best thing.
        var events = capture.events
        let size = capture.videoSize
        for index in events.indices where events[index].kind == .click && events[index].name == nil {
            guard let point = events[index].videoPoint, size.width > 0, size.height > 0,
                  let file = events[index].frameBefore ?? events[index].frame, let found = lines[file] else { continue }
            let near = AINotesFrameText.line(at: CGPoint(x: point.x / size.width, y: point.y / size.height), in: found)
            events[index].nearText = near.map { String($0.text.prefix(80)) }
            events[index].nearRow = near?.sameRow == true ? true : nil
        }
        if !capture.typing, !events.contains(where: { $0.kind == .click }) {
            // Without Input Monitoring access the click monitor may have seen nothing. The
            // take's pointer data has the clicks; they come without frames or names.
            let telemetry = video.deletingLastPathComponent().appendingPathComponent(CursorTelemetry.filename)
            events = merged(events, with: recordedClicks(in: telemetry, capture: capture))
        }

        var document = AINotesDocument()
        document.generator = generator
        document.title = video.deletingPathExtension().lastPathComponent
        document.recordedAt = capture.startedAt
        document.duration = duration ?? capture.duration
        document.source = capture.source
        document.system = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")), "
            + (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? "Dark" : "Light") + " appearance"
        document.video = .init(file: video.lastPathComponent, width: Int(size.width), height: Int(size.height))
        document.capture = .init(x: capture.captureRect.minX, y: capture.captureRect.minY,
                                 width: capture.captureRect.width, height: capture.captureRect.height,
                                 menuBar: capture.menuBarFraction > 0 ? capture.menuBarFraction : nil)
        document.narration = narration
        document.includes = .init(controlNames: capture.controlNames, typing: capture.typing)
        document.events = events
        document.frames = frames
        document.transcript = cues
        return document
    }

    // MARK: Clicks from pointer data

    private static func recordedClicks(in telemetry: URL, capture: AINotesCapture) -> [AINoteEvent] {
        guard let recording = CursorRecording.load(url: telemetry) else { return [] }
        return clickEvents(from: recording.clicks, capture: capture)
    }

    /// Pointer data records every press, including the one on the recorder's own Stop button,
    /// so presses outside the recorded area and in the last moments are left out.
    static func clickEvents(from clicks: [CursorRecording.Click], capture: AINotesCapture) -> [AINoteEvent] {
        clicks.compactMap { click in
            guard click.button != .other, (0...1).contains(click.position.x), (0...1).contains(click.position.y),
                  click.time < capture.duration - 0.5 else { return nil }
            var event = AINoteEvent(kind: .click, time: click.time)
            event.button = click.button == .right ? "right" : "left"
            let rect = capture.captureRect, size = capture.videoSize
            event.screenPoint = AINotePoint(CGPoint(x: rect.minX + click.position.x * rect.width,
                                                    y: rect.minY + click.position.y * rect.height))
            event.videoPoint = AINotePoint(CGPoint(x: min((click.position.x * size.width).rounded(), size.width - 1),
                                                   y: min((click.position.y * size.height).rounded(), size.height - 1)))
            return event
        }
    }

    private static func merged(_ events: [AINoteEvent], with extra: [AINoteEvent]) -> [AINoteEvent] {
        guard !extra.isEmpty else { return events }
        return (events + extra).enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    // MARK: Narration

    /// Transcribes the microphone track on this Mac. Never asks for permission: a prompt right
    /// after Stop would be a surprise, so without it the notes say why there is no transcript.
    @MainActor
    private static func narrate(video: URL, microphone: Bool, gate: AINotesNarrationGate) async -> (AINotesDocument.Narration, [AINotesCue]) {
        typealias Narration = AINotesDocument.Narration
        guard microphone else { return (Narration(status: "none", detail: "the microphone was off"), []) }
        let quit = "PressShot quit before the narration was transcribed"
        guard !gate.isSkipped else { return (Narration(status: "unavailable", detail: quit), []) }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return (Narration(status: "unavailable",
                              detail: "speech recognition is not allowed for PressShot in System Settings › Privacy & Security"), [])
        }
        do {
            // The microphone is the first audio track; system audio, when recorded, follows it.
            // Transcribing only the first keeps other people's voices and app sounds out.
            let asset = AVURLAsset(url: video)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                return (Narration(status: "none", detail: "the microphone produced no audio"), [])
            }
            let range = try await track.load(.timeRange)
            let composition = AVMutableComposition()
            guard let voice = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return (Narration(status: "unavailable", detail: "the microphone track could not be read"), [])
            }
            try voice.insertTimeRange(range, of: track, at: range.start)
            let task = Task { try await VideoCaptionTranscriber.transcribe(asset: composition, lease: nil) }
            gate.track(task)
            let words = try await task.value
            let cues = AINotesReport.cues(from: words.map { .init(text: $0.text, start: $0.start, end: $0.end) })
            return (Narration(status: "transcribed", language: Locale.current.identifier,
                              detail: cues.isEmpty ? "no speech was recognised" : nil), cues)
        } catch {
            if gate.isSkipped || error is CancellationError { return (Narration(status: "unavailable", detail: quit), []) }
            if case VideoCaptionTranscriber.TranscriptionError.noAudio = error {
                return (Narration(status: "none", detail: "the microphone produced no audio"), [])
            }
            if case VideoCaptionTranscriber.TranscriptionError.unavailable = error {
                return (Narration(status: "unavailable",
                                  detail: "on-device speech recognition is not available for \(Locale.current.identifier) on this Mac"), [])
            }
            return (Narration(status: "unavailable", detail: "transcription failed (\(error.localizedDescription))"), [])
        }
    }
}
