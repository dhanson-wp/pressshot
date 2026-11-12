import CoreGraphics
import CoreMedia
import Foundation

// AI notes: a written account of a recording (what was clicked, shown and
// said, with a few still frames) that an AI assistant can read instead of
// watching the video. Everything is produced on this Mac and stored in the
// take's own folder; see `AINotesLibrary` for the layout.

/// Maps global screen points to video pixels. Screen points are in Core
/// Graphics space: origin at the top-left of the primary display, y down, so
/// displays left of or above it have negative coordinates.
nonisolated struct AINotesGeometry: Equatable, Sendable {
    /// The recorded area, in points.
    var captureRect: CGRect
    /// Size of the recorded video, in pixels.
    var videoSize: CGSize

    /// nil when the point is outside the recorded area.
    func videoPoint(forScreenPoint point: CGPoint) -> CGPoint? {
        guard captureRect.width > 0, captureRect.height > 0, captureRect.contains(point) else { return nil }
        let x = (point.x - captureRect.minX) * videoSize.width / captureRect.width
        let y = (point.y - captureRect.minY) * videoSize.height / captureRect.height
        return CGPoint(x: min(x.rounded(), videoSize.width - 1), y: min(y.rounded(), videoSize.height - 1))
    }

    /// AppKit screen coordinates (origin bottom-left of the primary display) to Core Graphics space.
    static func cgPoint(fromAppKit point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }
}

/// Media time for note events: seconds from the first video frame with paused
/// intervals removed, exactly like `MP4WriterSession` and `CursorRecording`
/// remove them. Host times are seconds on the host clock, which
/// `NSEvent.timestamp` shares.
nonisolated struct AINotesTimeline: Equatable, Sendable {
    private(set) var origin: Double?
    private(set) var pausedTotal = 0.0
    private(set) var pausedSince: Double?

    var isStarted: Bool { origin != nil }
    var isPaused: Bool { pausedSince != nil }

    mutating func markStart(hostTime: Double) {
        guard origin == nil, hostTime.isFinite else { return }
        origin = hostTime
    }

    mutating func pause(hostTime: Double) {
        guard pausedSince == nil, hostTime.isFinite else { return }
        pausedSince = hostTime
    }

    mutating func resume(pausedDuration: Double) {
        guard pausedSince != nil else { return }
        if pausedDuration.isFinite { pausedTotal += max(pausedDuration, 0) }
        pausedSince = nil
    }

    /// nil before the first frame and while paused: nothing then is in the video.
    func mediaTime(forHost hostTime: Double) -> Double? {
        guard let origin, pausedSince == nil else { return nil }
        let time = hostTime - origin - pausedTotal
        return time.isFinite && time >= 0 ? time : nil
    }

    /// Length of the video so far. Holds still while paused.
    func elapsed(atHost hostTime: Double) -> Double {
        guard let origin else { return 0 }
        let time = (pausedSince ?? hostTime) - origin - pausedTotal
        return time.isFinite ? max(time, 0) : 0
    }
}

/// The timeline shared by everything that stamps note events during one take.
nonisolated final class AINotesClock: @unchecked Sendable {
    private let lock = NSLock()
    private var timeline = AINotesTimeline()

    static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private func withTimeline<T>(_ body: (inout AINotesTimeline) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&timeline)
    }

    func markStart(hostTime: Double) { withTimeline { $0.markStart(hostTime: hostTime) } }
    func pause(hostTime: Double = AINotesClock.hostNow()) { withTimeline { $0.pause(hostTime: hostTime) } }
    func resume(pausedDuration: Double) { withTimeline { $0.resume(pausedDuration: pausedDuration) } }
    func mediaTime(forHost hostTime: Double) -> Double? { withTimeline { $0.mediaTime(forHost: hostTime) } }
    var now: Double? { mediaTime(forHost: Self.hostNow()) }
    var elapsed: Double { withTimeline { $0.elapsed(atHost: Self.hostNow()) } }
    var isStarted: Bool { withTimeline { $0.isStarted } }
}

nonisolated struct AINotePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

/// One line of the timeline. Fields that do not apply to a kind stay nil and are left out of the JSON.
nonisolated struct AINoteEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case page, click, scroll, screen, typing, paused
    }

    var kind: Kind
    /// Seconds from the start of the video.
    var time: Double
    var duration: Double?
    var app: String?
    var title: String?
    var button: String?
    /// Where the click landed on screen, in points (Core Graphics space).
    var screenPoint: AINotePoint?
    /// The same spot in video pixels, from the top-left of the frame.
    var videoPoint: AINotePoint?
    /// Accessibility role and name of the clicked control (needs Accessibility access).
    var role: String?
    var name: String?
    /// For a click in a web page: the element's id and classes, CSS-style (`#id.class`).
    var selector: String?
    /// Text recognised under the click, when the control's name is not known.
    var nearText: String?
    /// True when `nearText` is level with the click but off to its side (the label of the row clicked).
    var nearRow: Bool?
    var direction: String?
    var detail: String?
    /// File names in `frames/`.
    var frame: String?
    var frameBefore: String?

    init(kind: Kind, time: Double) {
        self.kind = kind
        self.time = time
    }
}

/// One still image in the notes.
nonisolated struct AINotesFrame: Codable, Equatable, Sendable {
    var file: String
    /// Seconds from the start of the video.
    var time: Double
    var reason: String
    var width: Int
    var height: Int
    /// Text recognised in the frame, filled in after the recording stops.
    var text: String?
}

nonisolated struct AINotesCue: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// Everything in one set of notes, as stored in `events.json`. `llm.md` and
/// `transcript.vtt` are rendered from this.
nonisolated struct AINotesDocument: Codable, Equatable, Sendable {
    struct Video: Codable, Equatable, Sendable {
        var file = ""
        var width = 0
        var height = 0
    }

    /// The recorded area in screen points (Core Graphics space), for mapping `screenPoint` values.
    struct Capture: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        /// The menu bar's share of the frame height, when it is in the recording. Text there is not read.
        var menuBar: Double?
    }

    struct Narration: Codable, Equatable, Sendable {
        /// "transcribed", "none" or "unavailable".
        var status = "none"
        var language: String?
        var detail: String?
    }

    struct Includes: Codable, Equatable, Sendable {
        var controlNames = false
        var typing = false
    }

    static let currentFormat = 1

    var format = AINotesDocument.currentFormat
    var generator = ""
    var title = ""
    var recordedAt = Date(timeIntervalSince1970: 0)
    var duration = 0.0
    var source = ""
    var system = ""
    var video = Video()
    var capture: Capture?
    var narration = Narration()
    var includes = Includes()
    var events: [AINoteEvent] = []
    var frames: [AINotesFrame] = []
    var transcript: [AINotesCue] = []

    init() {}

    // Notes written by an older or newer build must still open: a missing or
    // unreadable field falls back to its default, and one unreadable event
    // costs that event, not the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.decode(.format, or: AINotesDocument.currentFormat)
        generator = c.decode(.generator, or: "")
        title = c.decode(.title, or: "")
        recordedAt = c.decode(.recordedAt, or: Date(timeIntervalSince1970: 0))
        duration = c.decode(.duration, or: 0)
        source = c.decode(.source, or: "")
        system = c.decode(.system, or: "")
        video = c.decode(.video, or: Video())
        capture = c.decodeOptional(.capture)
        narration = c.decode(.narration, or: Narration())
        includes = c.decode(.includes, or: Includes())
        events = c.decode(.events, or: Salvaged<AINoteEvent>()).values
        frames = c.decode(.frames, or: Salvaged<AINotesFrame>()).values
        transcript = c.decode(.transcript, or: Salvaged<AINotesCue>()).values
    }

    /// An array that keeps the elements it can read.
    private struct Salvaged<Element: Decodable>: Decodable {
        var values: [Element] = []

        init() {}

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            while !container.isAtEnd {
                if let value = try? container.decode(Element.self) {
                    values.append(value)
                } else {
                    _ = try? container.decode(Skipped.self)
                }
            }
        }

        private struct Skipped: Decodable {
            init(from decoder: Decoder) throws {}
        }
    }
}

nonisolated extension AINotesDocument.Video {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = c.decode(.file, or: "")
        width = c.decode(.width, or: 0)
        height = c.decode(.height, or: 0)
    }
}

nonisolated extension AINotesDocument.Narration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.decode(.status, or: "none")
        language = c.decodeOptional(.language)
        detail = c.decodeOptional(.detail)
    }
}

nonisolated extension AINotesDocument.Includes {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controlNames = c.decode(.controlNames, or: false)
        typing = c.decode(.typing, or: false)
    }
}
