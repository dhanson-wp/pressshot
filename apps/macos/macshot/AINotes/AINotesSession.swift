import AppKit
import CoreGraphics

/// What the person chose for AI notes on one recording.
nonisolated struct AINotesOptions: Equatable, Sendable {
    /// Name clicked controls through Accessibility, when access has been granted.
    var controlNames = true

    static let enabledKey = "recordAINotes"
    static let controlNamesKey = "aiNotesControlNames"

    /// The options for the next take, or nil when AI notes are off.
    static func current(_ defaults: UserDefaults = .standard) -> AINotesOptions? {
        guard defaults.bool(forKey: enabledKey) else { return nil }
        return AINotesOptions(controlNames: defaults.object(forKey: controlNamesKey) as? Bool ?? true)
    }
}

/// What a recording hands over when it stops: the raw timeline and frames, before transcription
/// and text recognition.
nonisolated struct AINotesCapture: Sendable {
    /// The take's `ai-notes` folder.
    var folder: URL
    var startedAt: Date
    var source: String
    var captureRect: CGRect
    /// The menu bar's share of the frame height when it is in the recording, else 0.
    var menuBarFraction = 0.0
    var videoSize: CGSize
    /// Length of the video as the notes clock saw it.
    var duration: Double
    var controlNames: Bool
    var typing: Bool
    var microphone: Bool
    var events: [AINoteEvent]
    var frames: [AINotesFrame]
    /// Click frames waiting for their ring, by file name: where to draw it, as a fraction of the frame.
    var rings: [String: CGPoint] = [:]
    /// Text already read from frames while the recording ran, by file name.
    var recognized: [String: [AINotesFrameText.Line]] = [:]

    /// Removes what was written; the recording itself is untouched.
    func discard() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Runs the note-taking side of one recording: the timeline, the monitors that feed it, and the
/// key frames. `RecordingEngine` owns it the way it owns pointer telemetry: nothing here can
/// fail or delay the take.
nonisolated final class AINotesSession: @unchecked Sendable {
    let folder: URL
    let frames: AINotesFrameSink
    private let clock = AINotesClock()
    private let recorder: AINotesEventRecorder
    private let focus: AINotesFocusMonitor
    private let reader: AINotesFrameReader
    private let geometry: AINotesGeometry
    private let menuBarFraction: Double
    private let source: String
    private let microphone: Bool
    private let controlNames: Bool
    private let startedAt = Date()
    private var input: AINotesInputMonitor?
    private var watchedKeys = false
    private var ended = false

    /// - Parameters:
    ///   - region: Recorded area in global Core Graphics coordinates.
    ///   - menuBarFraction: See `menuBarFraction(region:displayID:)`.
    init(takeFolder: URL, region: CGRect, videoSize: CGSize, options: AINotesOptions,
         microphone: Bool, menuBarFraction: Double) throws {
        folder = AINotesLibrary.folder(forTake: takeFolder)
        geometry = AINotesGeometry(captureRect: region, videoSize: videoSize)
        self.menuBarFraction = menuBarFraction
        self.microphone = microphone
        source = "Screen area \(Int(region.width))×\(Int(region.height)) pt"
        // Without Accessibility access there is nothing to ask; clicks keep the text under them.
        controlNames = options.controlNames && AINotesElementInspector.isTrusted
        let reader = AINotesFrameReader(ignoringTop: menuBarFraction)
        self.reader = reader
        frames = try AINotesFrameSink(directory: folder.appendingPathComponent(AINotesLibrary.framesName),
                                      clock: clock, videoSize: videoSize, onStore: { [reader] in reader.enqueue($0) })
        let recorder = AINotesEventRecorder(clock: clock, options: .init(controlNames: controlNames),
                                            frames: frames, geometry: geometry)
        self.recorder = recorder
        focus = AINotesFocusMonitor { [weak recorder] in recorder?.focusChanged($0) }
    }

    /// The menu bar's share of a recording's height: recognised text there (status icons) is noise.
    @MainActor
    static func menuBarFraction(region: CGRect, displayID: CGDirectDisplayID) -> Double {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID }
        // 24 points on most displays, 37 or so beside a notch.
        let bar = max(screen?.safeAreaInsets.top ?? 0, NSStatusBar.system.thickness, 24)
        return menuBarFraction(region: region, displayBounds: CGDisplayBounds(displayID), barHeight: bar)
    }

    static func menuBarFraction(region: CGRect, displayBounds: CGRect, barHeight: CGFloat) -> Double {
        guard region.height > 0 else { return 0 }
        let covered = barHeight - (region.minY - displayBounds.minY)
        return covered > 0 ? Double(min(covered / region.height, 1)) : 0
    }

    /// Called on the writer queue with the host time of the first video frame.
    func markStart(hostTime: Double) {
        clock.markStart(hostTime: hostTime)
    }

    /// Recording is live: start watching input and the front window.
    @MainActor
    func start() {
        guard !ended, input == nil else { return }
        frames.start()
        focus.start()
        let input = AINotesInputMonitor(recorder: recorder)
        input.start()
        self.input = input
        watchedKeys = AINotesInputMonitor.canWatchKeys
    }

    /// A click at a screen point (Core Graphics space), as if the monitor had seen it. For tests
    /// and drivers that have no real pointer.
    func recordClick(at point: CGPoint, button: String = "left") {
        recorder.click(at: point, button: button, uptime: AINotesClock.hostNow())
    }

    func pause() {
        clock.pause()
        recorder.setPaused(true)
    }

    func resume(pausedDuration: Double) {
        clock.resume(pausedDuration: pausedDuration)
        recorder.setPaused(false, pausedDuration: pausedDuration)
    }

    /// Stops collecting and returns what was gathered. Returns nil when it was already ended.
    @MainActor
    func stop() -> AINotesCapture? {
        guard !ended else { return nil }
        ended = true
        focus.stop()
        input?.stop()
        input = nil
        // Stop reading before the frames are renamed; what is not read yet is read afterwards.
        let read = reader.stop()
        let duration = clock.elapsed
        let result = recorder.finish(duration: duration)
        var recognized: [String: [AINotesFrameText.Line]] = [:]
        for (file, source) in result.frames.sources {
            if let lines = read[source] { recognized[file] = lines }
        }
        return AINotesCapture(folder: folder, startedAt: startedAt, source: source, captureRect: geometry.captureRect,
                              menuBarFraction: menuBarFraction, videoSize: geometry.videoSize, duration: duration,
                              controlNames: controlNames, typing: watchedKeys, microphone: microphone,
                              events: result.events, frames: result.frames.frames, rings: result.frames.rings,
                              recognized: recognized)
    }

    /// The recording was abandoned: stop everything and remove what was written.
    @MainActor
    func cancel() {
        guard !ended else { return }
        ended = true
        focus.stop()
        input?.stop()
        input = nil
        _ = reader.stop()
        recorder.abandon()
        frames.discard()
        try? FileManager.default.removeItem(at: folder)
    }
}
