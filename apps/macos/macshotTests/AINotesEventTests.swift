import CoreGraphics
import XCTest

/// Turning raw input into timeline lines, and naming clicks from screen text.
final class AINotesEventTests: XCTestCase {

    func testScrollEventsFoldIntoBursts() {
        typealias Burst = AINotesScrollCoalescer.Burst
        var coalescer = AINotesScrollCoalescer()
        XCTAssertNil(coalescer.add(time: 1.0, dx: 0, dy: -4, app: "Safari"))
        XCTAssertNil(coalescer.add(time: 1.2, dx: 0, dy: -9, app: "Safari"))
        XCTAssertNil(coalescer.add(time: 1.9, dx: 1, dy: -3, app: "Safari"), "a gap under the limit continues the burst")
        XCTAssertNil(coalescer.flush(at: 2.0), "a burst that is still fresh is not flushed")
        XCTAssertEqual(coalescer.add(time: 4.0, dx: 0, dy: 6, app: "Safari"), Burst(start: 1.0, end: 1.9, direction: "down", app: "Safari"))
        XCTAssertEqual(coalescer.add(time: 4.1, dx: 0, dy: 2, app: "Notes"), Burst(start: 4.0, end: 4.0, direction: "up", app: "Safari"),
                       "another app starts a new burst")
        XCTAssertEqual(coalescer.flush(at: 5.5), Burst(start: 4.1, end: 4.1, direction: "up", app: "Notes"))
        XCTAssertNil(coalescer.flush())
        _ = coalescer.add(time: 9, dx: -30, dy: 2, app: nil)
        XCTAssertEqual(coalescer.flush()?.direction, "right", "mostly horizontal movement reads as sideways")
    }

    func testKeyPressesFoldIntoTypingSpans() {
        typealias Span = AINotesTypingCoalescer.Span
        var coalescer = AINotesTypingCoalescer()
        XCTAssertFalse(coalescer.isActive)
        XCTAssertNil(coalescer.add(time: 2.0))
        XCTAssertNil(coalescer.add(time: 2.3))
        XCTAssertNil(coalescer.add(time: 3.8), "a pause shorter than the gap continues the span")
        XCTAssertTrue(coalescer.isActive)
        XCTAssertEqual(coalescer.add(time: 9.0), Span(start: 2.0, end: 3.8), "a long pause ends the span")
        XCTAssertEqual(coalescer.flush(), Span(start: 9.0, end: 9.0))
        XCTAssertNil(coalescer.flush())
        XCTAssertFalse(coalescer.isActive)
    }

    func testTimelineNamesFramesAndExplainsUnpromptedChanges() {
        var frames = AINotesFrameStore.Result()
        frames.frames = [
            AINotesFrame(file: "f01-00m00s-start.jpg", time: 0, reason: "start", width: 2, height: 2),
            AINotesFrame(file: "f02-00m03s-before-click.jpg", time: 3, reason: "before-click", width: 2, height: 2),
            AINotesFrame(file: "f03-00m03s-click.jpg", time: 3.15, reason: "click", width: 2, height: 2),
            AINotesFrame(file: "f04-00m05s-screen.jpg", time: 5.5, reason: "screen", width: 2, height: 2),
            AINotesFrame(file: "f05-01m40s-screen.jpg", time: 100, reason: "screen", width: 2, height: 2),
        ]
        frames.files = [7: "f03-00m03s-click.jpg"]
        frames.beforeFiles = [7: "f02-00m03s-before-click.jpg"]
        var paused = AINoteEvent(kind: .paused, time: 60)
        paused.duration = 12
        let page = AINoteEvent(kind: .page, time: 60)
        let events = AINotesEventRecorder.timeline([
            (AINoteEvent(kind: .click, time: 3), 7), (paused, nil), (page, nil), (AINoteEvent(kind: .scroll, time: 1), 99),
        ], frames: frames)

        XCTAssertEqual(events.map(\.kind), [.scroll, .click, .screen, .paused, .page, .screen])
        XCTAssertEqual(events[1].frame, "f03-00m03s-click.jpg")
        XCTAssertEqual(events[1].frameBefore, "f02-00m03s-before-click.jpg")
        XCTAssertNil(events[0].frame, "a scroll that changed nothing keeps no frame")
        XCTAssertEqual(events[2].detail, "screen changed 2.5 s after the last click")
        XCTAssertEqual(events[5].detail, "screen changed, no input")
        XCTAssertEqual(events[5].frame, "f05-01m40s-screen.jpg")
    }

    func testFrontWindowSkipsOurOwnWindowsAndSmallPanels() {
        func window(_ pid: Int32, _ app: String, _ title: String, layer: Int = 0, size: CGSize = CGSize(width: 800, height: 600)) -> [String: Any] {
            [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid, kCGWindowOwnerName as String: app,
             kCGWindowName as String: title,
             kCGWindowBounds as String: CGRect(origin: .zero, size: size).dictionaryRepresentation as NSDictionary]
        }
        let list = [
            window(10, "PressShot", "Recording controls"),
            window(20, "Dock", "", layer: 20),
            window(30, "Safari", "Tooltip", size: CGSize(width: 90, height: 30)),
            window(30, "Safari", "Checkout – Example Store"),
            window(40, "Notes", "Shopping"),
        ]
        let focus = AINotesFocusMonitor.frontmost(in: list, ownPID: 10) { $0 == 30 ? "com.apple.Safari" : nil }
        XCTAssertEqual(focus, AINotesFocus(app: "Safari", bundleID: "com.apple.Safari", title: "Checkout – Example Store", pid: 30))
        XCTAssertNil(AINotesFocusMonitor.frontmost(in: [window(10, "PressShot", "Editor")], ownPID: 10) { _ in nil })
    }

    func testBrowserLedgerRemembersWhatARecordingSwitchedOn() throws {
        let suite = TestDefaultsSuite.uniqueName("ai-notes-ledger")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaultsSuite.remove(defaults, named: suite) }
        let ledger = AINotesBrowserLedger(defaults: defaults)
        XCTAssertTrue(ledger.entries.isEmpty)

        ledger.add(pid: 410, bundleID: "com.google.Chrome")
        ledger.add(pid: 512, bundleID: "com.brave.Browser")
        ledger.add(pid: 410, bundleID: "com.google.Chrome")
        XCTAssertEqual(ledger.entries, [.init(pid: 512, bundleID: "com.brave.Browser"),
                                        .init(pid: 410, bundleID: "com.google.Chrome")])
        // A second ledger on the same defaults sees them: this is what survives a crash.
        XCTAssertEqual(AINotesBrowserLedger(defaults: defaults).entries.count, 2)

        ledger.remove(pid: 512)
        XCTAssertEqual(ledger.entries, [.init(pid: 410, bundleID: "com.google.Chrome")])
        ledger.remove(pid: 410)
        XCTAssertNil(defaults.object(forKey: AINotesBrowserLedger.key))
    }

    func testOnlyBrowsersStillRunningAsTheSameAppAreRestored() {
        let remembered: [AINotesBrowserLedger.Entry] = [
            .init(pid: 410, bundleID: "com.google.Chrome"),
            .init(pid: 512, bundleID: "com.brave.Browser"),
            .init(pid: 613, bundleID: "com.microsoft.edgemac"),
        ]
        let running: [AINotesBrowserLedger.Entry] = [
            .init(pid: 410, bundleID: "com.google.Chrome"),
            // Brave quit and its process id went to another app.
            .init(pid: 512, bundleID: "com.apple.Notes"),
        ]
        XCTAssertEqual(AINotesBrowserLedger.stillRunning(remembered, among: running),
                       [.init(pid: 410, bundleID: "com.google.Chrome")])
    }

    func testChromiumBrowsersAreRecognised() {
        XCTAssertTrue(AINotesElementInspector.isChromium("com.google.Chrome"))
        XCTAssertTrue(AINotesElementInspector.isChromium("com.microsoft.edgemac"))
        XCTAssertFalse(AINotesElementInspector.isChromium("com.apple.Safari"))
    }

    // MARK: Screen text

    private typealias Line = AINotesFrameText.Line

    func testClickIsNamedByTheTextUnderIt() {
        let lines = [
            Line(text: "Place order", box: CGRect(x: 0.40, y: 0.50, width: 0.20, height: 0.04)),
            Line(text: "Checkout", box: CGRect(x: 0.05, y: 0.05, width: 0.30, height: 0.06)),
            Line(text: "Standard shipping", box: CGRect(x: 0.05, y: 0.70, width: 0.25, height: 0.03)),
        ]
        XCTAssertEqual(AINotesFrameText.line(at: CGPoint(x: 0.5, y: 0.52), in: lines)?.text, "Place order")
        XCTAssertEqual(AINotesFrameText.line(at: CGPoint(x: 0.5, y: 0.52), in: lines)?.sameRow, false)
        // An arrow at the end of a row: level with the label, some way to its side.
        let row = AINotesFrameText.line(at: CGPoint(x: 0.6, y: 0.715), in: lines)
        XCTAssertEqual(row?.text, "Standard shipping")
        XCTAssertEqual(row?.sameRow, true)
        XCTAssertNil(AINotesFrameText.line(at: CGPoint(x: 0.9, y: 0.3), in: lines), "empty space has no name")
    }

    func testRecognisedTextIsFilteredAndRedacted() throws {
        // A made-up key, assembled so secret scanners do not flag this file.
        let secret = ["sk", "live", "51H8xQ2LkJhGfDsAzXcVbNmQwErTy"].joined(separator: "_")
        let observations = [
            // Vision boxes have a bottom-left origin.
            OCRTextObservation(text: "Secret key: \(secret)", boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.5, height: 0.05),
                               substringBounds: { _ in CGRect(x: 0.3, y: 0.6, width: 0.3, height: 0.05) }),
            OCRTextObservation(text: "Card 4242 4242 4242 4242", boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.4, height: 0.05)),
            OCRTextObservation(text: "ONIOR", boundingBox: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05), confidence: 0.2),
            OCRTextObservation(text: "x", boundingBox: CGRect(x: 0.7, y: 0.5, width: 0.01, height: 0.02)),
            OCRTextObservation(text: "Wi-Fi", boundingBox: CGRect(x: 0.8, y: 0.98, width: 0.05, height: 0.015)),
            OCRTextObservation(text: " Place order ", boundingBox: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.04)),
        ]
        let lines = AINotesFrameText.lines(from: observations, ignoringTop: 0.03)
        XCTAssertEqual(lines.map(\.text), ["Secret key: [redacted]", "Card [redacted]", "Place order"],
                       "low-confidence guesses, single characters and the menu bar are left out")
        XCTAssertFalse(lines.contains { $0.text.contains(secret) })

        // The exact box from the recogniser, flipped to a top-left origin.
        let exact = try XCTUnwrap(lines[0].secret)
        XCTAssertEqual(exact.minY, 0.35, accuracy: 0.01)
        XCTAssertEqual(exact.minX, 0.3, accuracy: 0.01)
        XCTAssertEqual(lines[0].box.minY, 0.35, accuracy: 1e-9)
        // No substring box: estimated from character positions, leaving the label readable.
        let estimated = try XCTUnwrap(lines[1].secret)
        XCTAssertGreaterThan(estimated.minX, 0.1 + 0.4 * 0.1)
        XCTAssertEqual(estimated.maxX, 0.5, accuracy: 0.001)
        XCTAssertNil(lines[2].secret)
    }

    func testAssemblyNamesClicksFromScreenTextAndKeepsUnreadFramesHonest() throws {
        let take = FileManager.default.temporaryDirectory.appendingPathComponent("pressshot-ai-assemble-\(UUID().uuidString)")
        let folder = AINotesLibrary.folder(forTake: take)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(AINotesLibrary.framesName), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: take) }
        var click = AINoteEvent(kind: .click, time: 3)
        click.videoPoint = AINotePoint(CGPoint(x: 400, y: 312))
        click.frame = "f02-00m03s-click.jpg"
        var named = AINoteEvent(kind: .click, time: 5)
        named.videoPoint = AINotePoint(CGPoint(x: 400, y: 312))
        named.name = "Pay now"
        named.frame = "f02-00m03s-click.jpg"
        let capture = AINotesCapture(
            folder: folder, startedAt: Date(timeIntervalSince1970: 100), source: "Screen area 400×300 pt",
            captureRect: CGRect(x: 0, y: 0, width: 400, height: 300), menuBarFraction: 0.08, videoSize: CGSize(width: 800, height: 600),
            duration: 9, controlNames: true, typing: true, microphone: false, events: [click, named],
            frames: [AINotesFrame(file: "f01-00m00s-start.jpg", time: 0, reason: "start", width: 800, height: 600),
                     AINotesFrame(file: "f02-00m03s-click.jpg", time: 3.15, reason: "click", width: 800, height: 600)])
        let lines = ["f02-00m03s-click.jpg": [Line(text: "Place order", box: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.04))]]
        let document = AINotesBuilder.assemble(capture, video: take.appendingPathComponent("Checkout bug.mp4"), lines: lines,
                                               narration: .init(status: "none", language: nil, detail: "the microphone was off"),
                                               cues: [], duration: nil)
        XCTAssertEqual(document.title, "Checkout bug")
        XCTAssertEqual(document.video.file, "Checkout bug.mp4")
        XCTAssertEqual(document.duration, 9, "the notes clock stands in when the video cannot be read")
        XCTAssertEqual(document.capture?.menuBar, 0.08)
        XCTAssertTrue(document.generator.hasPrefix("PressShot "))
        XCTAssertEqual(document.events[0].nearText, "Place order")
        XCTAssertNil(document.events[1].nearText, "a control with a name needs no guess")
        XCTAssertNil(document.frames[0].text, "a frame that was never read has no text, not empty text")
        XCTAssertEqual(document.frames[1].text, "Place order")
        XCTAssertTrue(AINotesReport.render(document).contains("00:03  [click]  near \"Place order\" at (400, 312)   → frames/f02-00m03s-click.jpg"))
    }

    // MARK: Clicks from pointer data

    func testPointerDataFillsInClicksInsideTheRecording() {
        let capture = AINotesCapture(folder: URL(fileURLWithPath: "/nonexistent"), startedAt: Date(), source: "Screen area",
                                     captureRect: CGRect(x: 100, y: 200, width: 400, height: 300), videoSize: CGSize(width: 800, height: 600),
                                     duration: 20, controlNames: false, typing: false, microphone: false, events: [], frames: [])
        let events = AINotesBuilder.clickEvents(from: [
            .init(time: 2, upTime: nil, button: .left, position: CGPoint(x: 0.5, y: 0.25)),
            .init(time: 4, upTime: nil, button: .right, position: CGPoint(x: 1, y: 1)),
            .init(time: 5, upTime: nil, button: .left, position: CGPoint(x: 1.2, y: 0.5)),   // outside the area
            .init(time: 6, upTime: nil, button: .other, position: CGPoint(x: 0.5, y: 0.5)),
            .init(time: 19.8, upTime: nil, button: .left, position: CGPoint(x: 0.5, y: 0.5)), // the press on Stop
        ], capture: capture)
        XCTAssertEqual(events.map(\.time), [2, 4])
        XCTAssertEqual(events[0].videoPoint, AINotePoint(CGPoint(x: 400, y: 150)))
        XCTAssertEqual(events[0].screenPoint, AINotePoint(CGPoint(x: 300, y: 275)))
        XCTAssertEqual(events[0].button, "left")
        XCTAssertEqual(events[1].button, "right")
        XCTAssertEqual(events[1].videoPoint, AINotePoint(CGPoint(x: 799, y: 599)), "the far corner stays inside the frame")
    }
}
