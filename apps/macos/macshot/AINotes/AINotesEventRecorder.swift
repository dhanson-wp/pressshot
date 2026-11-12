import CoreGraphics
import Foundation

/// Folds a stream of scroll-wheel events into "scrolled down in Safari for 2 s".
nonisolated struct AINotesScrollCoalescer: Sendable {
    struct Burst: Equatable, Sendable {
        var start: Double
        var end: Double
        var direction: String
        var app: String?
    }

    /// A pause longer than this ends a burst.
    static let gap = 0.8

    private var start = 0.0
    private var end = 0.0
    private var dx = 0.0
    private var dy = 0.0
    private var app: String?
    private var active = false

    /// Returns the burst that just ended, if this event starts a new one.
    mutating func add(time: Double, dx: Double, dy: Double, app: String?) -> Burst? {
        var finished: Burst?
        if active, time - end > Self.gap || app != self.app {
            finished = current
            active = false
        }
        if !active {
            active = true
            start = time
            end = time
            self.dx = 0
            self.dy = 0
            self.app = app
        }
        end = max(end, time)
        self.dx += dx
        self.dy += dy
        return finished
    }

    /// Ends the burst in progress when it has been quiet since `time - gap`; pass nil to end it regardless.
    mutating func flush(at time: Double? = nil) -> Burst? {
        guard active else { return nil }
        if let time, time - end <= Self.gap { return nil }
        active = false
        return current
    }

    private var current: Burst {
        // A positive vertical delta moves the content down, which reads as scrolling up.
        let direction: String
        if abs(dy) >= abs(dx) {
            direction = dy > 0 ? "up" : "down"
        } else {
            direction = dx > 0 ? "left" : "right"
        }
        return Burst(start: start, end: end, direction: direction, app: app)
    }
}

/// Folds key presses into spans of typing. Only the times are kept, never the keys.
nonisolated struct AINotesTypingCoalescer: Sendable {
    struct Span: Equatable, Sendable {
        var start: Double
        var end: Double
    }

    /// Typing that stops for this long ends the span.
    static let gap = 1.6

    private var span: Span?

    var isActive: Bool { span != nil }

    /// Returns the span that just ended, if this key starts a new one.
    mutating func add(time: Double) -> Span? {
        var finished: Span?
        if let current = span, time - current.end > Self.gap {
            finished = current
            span = nil
        }
        if let current = span {
            span = Span(start: current.start, end: max(current.end, time))
        } else {
            span = Span(start: time, end: time)
        }
        return finished
    }

    mutating func flush() -> Span? {
        defer { span = nil }
        return span
    }
}

/// Collects the timeline of one recording: clicks, scrolls, typing, window
/// changes. Times are media times from the shared clock, so they line up with
/// the video. Everything runs on one serial queue.
nonisolated final class AINotesEventRecorder: @unchecked Sendable {
    struct Options: Equatable, Sendable {
        /// Name clicked controls and typed-in fields through Accessibility.
        var controlNames = false
    }

    struct Result {
        var events: [AINoteEvent]
        var frames: AINotesFrameStore.Result
    }

    private struct Entry {
        var event: AINoteEvent
        var frameID: Int?
    }

    private let queue = DispatchQueue(label: "com.derekhanson.pressshot.ai-notes.events")
    private let clock: AINotesClock
    private let options: Options
    private let frames: AINotesFrameSink
    private let geometry: AINotesGeometry

    private var entries: [Entry] = []
    private var scroll = AINotesScrollCoalescer()
    private var scrollGeneration = 0
    private var typing = AINotesTypingCoalescer()
    private var typingGeneration = 0
    private var typingField: AINotesElementInspector.Element?
    private var typingFieldChecked = -Double.infinity
    private var focus: AINotesFocus?
    private var pausedAt: Double?
    private var finished = false
    /// Browsers whose web-page accessibility this recording switched on, to switch off at the end.
    private var exposedBrowsers: Set<pid_t> = []

    init(clock: AINotesClock, options: Options, frames: AINotesFrameSink, geometry: AINotesGeometry) {
        self.clock = clock
        self.options = options
        self.frames = frames
        self.geometry = geometry
    }

    // MARK: Input

    /// `uptime` is `NSEvent.timestamp`, which shares the host clock with the video timestamps.
    func click(at screenPoint: CGPoint, button: String, uptime: Double) {
        queue.async { [self] in
            guard !finished, let time = clock.mediaTime(forHost: uptime),
                  let videoPoint = geometry.videoPoint(forScreenPoint: screenPoint) else { return }
            var event = AINoteEvent(kind: .click, time: time)
            event.button = button
            event.screenPoint = AINotePoint(screenPoint)
            event.videoPoint = AINotePoint(videoPoint)
            event.app = focus?.app
            // Ask for the frame first: naming the control can take a moment.
            let frameID = frames.requestClick(time: time, at: videoPoint)
            if options.controlNames {
                let chromium = focus?.bundleID.map(AINotesElementInspector.isChromium) ?? false
                if let element = AINotesElementInspector.element(at: screenPoint, askTwice: chromium) {
                    event.role = element.role
                    event.name = element.name.map { AINotesRedactor.redact($0) }
                    event.selector = element.selector.map { AINotesRedactor.redact($0) }
                }
            }
            entries.append(Entry(event: event, frameID: frameID))
        }
    }

    func scroll(dx: Double, dy: Double, uptime: Double) {
        queue.async { [self] in
            guard !finished, dx != 0 || dy != 0, let time = clock.mediaTime(forHost: uptime) else { return }
            if let burst = scroll.add(time: time, dx: dx, dy: dy, app: focus?.app) { record(burst) }
            scrollGeneration += 1
            let generation = scrollGeneration
            queue.asyncAfter(deadline: .now() + AINotesScrollCoalescer.gap + 0.1) { [self] in
                guard generation == scrollGeneration, !finished, let burst = scroll.flush() else { return }
                record(burst)
            }
        }
    }

    /// A key went down. Only the fact is kept, never which key.
    func keyPressed(uptime: Double) {
        queue.async { [self] in
            guard !finished, let time = clock.mediaTime(forHost: uptime) else { return }
            // Which field has the keyboard, by its label only. Looked up now and then, so moving
            // to the next field with Tab starts a new line in the timeline.
            if options.controlNames, !typing.isActive || time - typingFieldChecked > 0.7, let pid = focus?.pid {
                typingFieldChecked = time
                let field = AINotesElementInspector.focusedField(pid: pid)
                if typing.isActive, field != typingField { flushTyping() }
                typingField = field
            }
            if let ended = typing.add(time: time) { record(ended) }
            typingGeneration += 1
            let generation = typingGeneration
            queue.asyncAfter(deadline: .now() + AINotesTypingCoalescer.gap) { [self] in
                guard generation == typingGeneration, !finished else { return }
                flushTyping()
            }
        }
    }

    func focusChanged(_ next: AINotesFocus) {
        queue.async { [self] in
            guard !finished else { return }
            let previous = focus
            focus = next
            // Chromium apps build their accessibility tree only once something asks for it, and the
            // first answers come back empty. Ask now so the first real click already has a name.
            if options.controlNames, previous?.app != next.app {
                if let bundleID = next.bundleID, AINotesElementInspector.isChromium(bundleID), !exposedBrowsers.contains(next.pid),
                   AINotesElementInspector.exposeWebContent(pid: next.pid) {
                    exposedBrowsers.insert(next.pid)
                }
                _ = AINotesElementInspector.element(at: CGPoint(x: geometry.captureRect.midX, y: geometry.captureRect.midY))
            }
            guard previous?.app != next.app || previous?.title != next.title, let time = clock.now else { return }
            recordPage(next, time: time)
        }
    }

    /// The recording was paused or resumed. Paused time is cut from the video, so the timeline
    /// only marks where the cut is.
    func setPaused(_ paused: Bool, pausedDuration: Double = 0) {
        queue.async { [self] in
            guard !finished else { return }
            if paused {
                guard pausedAt == nil else { return }
                flushPending()
                pausedAt = clock.elapsed
                frames.setPaused(true)
            } else if let at = pausedAt {
                pausedAt = nil
                frames.setPaused(false)
                var event = AINoteEvent(kind: .paused, time: at)
                event.duration = max(pausedDuration, 0)
                entries.append(Entry(event: event, frameID: nil))
                if let focus { recordPage(focus, time: at) }
            }
        }
    }

    /// The recording was abandoned: stop collecting and undo what was switched on in other apps.
    func abandon() {
        queue.sync {
            finished = true
            exposedBrowsers.forEach(AINotesElementInspector.restoreWebContent)
            exposedBrowsers = []
        }
    }

    /// Ends collection and returns the timeline in time order, with frame file names filled in.
    func finish(duration: Double) -> Result {
        queue.sync {
            flushPending()
            finished = true
            exposedBrowsers.forEach(AINotesElementInspector.restoreWebContent)
            exposedBrowsers = []
        }
        let result = frames.finish(duration: duration)
        let events: [AINoteEvent] = queue.sync {
            Self.timeline(entries.map { ($0.event, $0.frameID) }, frames: result)
        }
        return Result(events: events, frames: result)
    }

    /// Fills in frame names and adds a line for each frame taken without any input.
    static func timeline(_ entries: [(event: AINoteEvent, frameID: Int?)], frames result: AINotesFrameStore.Result) -> [AINoteEvent] {
        var events = entries.map { entry -> AINoteEvent in
            var event = entry.event
            if let id = entry.frameID {
                event.frame = result.files[id]
                event.frameBefore = result.beforeFiles[id]
            }
            return event
        }
        for frame in result.frames where frame.reason == AINotesFrameSink.Reason.screen.rawValue {
            guard !events.contains(where: { $0.frame == frame.file }) else { continue }
            var event = AINoteEvent(kind: .screen, time: frame.time)
            event.frame = frame.file
            // How long after the last input: the difference between "the click did this" and
            // "this happened by itself", and the length of any wait in between.
            let lastInput = events.filter { ($0.kind == .click || $0.kind == .scroll || $0.kind == .typing) && $0.time <= frame.time }
                .max { $0.time + ($0.duration ?? 0) < $1.time + ($1.duration ?? 0) }
            if let lastInput, frame.time - (lastInput.time + (lastInput.duration ?? 0)) < 30 {
                let gap = max(frame.time - (lastInput.time + (lastInput.duration ?? 0)), 0)
                let what = lastInput.kind == .click ? "click" : lastInput.kind == .scroll ? "scroll" : "typing"
                event.detail = String(format: "screen changed %.1f s after the last %@", gap, what)
            } else {
                event.detail = "screen changed, no input"
            }
            events.append(event)
        }
        // Stable, so a pause marker stays ahead of the page line recorded at the same moment.
        return events.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    // MARK: Queue-confined helpers

    private func flushPending() {
        if let burst = scroll.flush() { record(burst) }
        flushTyping()
    }

    private func record(_ burst: AINotesScrollCoalescer.Burst) {
        var event = AINoteEvent(kind: .scroll, time: burst.start)
        event.duration = burst.end - burst.start
        event.direction = burst.direction
        event.app = burst.app
        // Kept only if the screen now differs from the last frame.
        let id = frames.request(.screen, time: burst.end, delay: 0.25, minimumChange: 0.01)
        entries.append(Entry(event: event, frameID: id))
    }

    private func flushTyping() {
        if let span = typing.flush() { record(span) }
    }

    private func record(_ span: AINotesTypingCoalescer.Span) {
        var event = AINoteEvent(kind: .typing, time: span.start)
        event.duration = span.end - span.start
        event.app = focus?.app
        event.role = typingField?.role
        event.name = typingField?.name.map { AINotesRedactor.redact($0) }
        entries.append(Entry(event: event, frameID: nil))
    }

    private func recordPage(_ focus: AINotesFocus, time: Double) {
        let title = AINotesRedactor.redact(focus.title)
        // A title that keeps changing (a counter, a spinner) updates the line instead of adding one.
        if let last = entries.indices.last, entries[last].event.kind == .page,
           entries[last].event.app == focus.app, time - entries[last].event.time < 2 {
            entries[last].event.title = title
        } else {
            var event = AINoteEvent(kind: .page, time: time)
            event.app = focus.app
            event.title = title
            entries.append(Entry(event: event, frameID: frames.request(.page, time: time, delay: 0.35)))
        }
    }
}
