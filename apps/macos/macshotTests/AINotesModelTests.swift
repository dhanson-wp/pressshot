import CoreGraphics
import XCTest

/// AI notes geometry, the pause-aware clock, and the persisted document.
final class AINotesModelTests: XCTestCase {

    // MARK: Geometry

    func testScreenPointsMapToVideoPixels() {
        let main = AINotesGeometry(captureRect: CGRect(x: 0, y: 0, width: 1512, height: 982), videoSize: CGSize(width: 1512, height: 982))
        XCTAssertEqual(main.videoPoint(forScreenPoint: CGPoint(x: 100, y: 50)), CGPoint(x: 100, y: 50))
        XCTAssertNil(main.videoPoint(forScreenPoint: CGPoint(x: 1512, y: 50)), "the right edge is outside")
        XCTAssertNil(main.videoPoint(forScreenPoint: CGPoint(x: -1, y: 50)))

        let retina = AINotesGeometry(captureRect: CGRect(x: 0, y: 0, width: 1512, height: 982), videoSize: CGSize(width: 3024, height: 1964))
        XCTAssertEqual(retina.videoPoint(forScreenPoint: CGPoint(x: 706, y: 440)), CGPoint(x: 1412, y: 880))
        XCTAssertEqual(retina.videoPoint(forScreenPoint: CGPoint(x: 1511.9, y: 981.9)), CGPoint(x: 3023, y: 1963),
                       "the last point stays inside the frame")
    }

    func testAreasOnDisplaysWithNegativeOriginsMap() {
        // A display to the left of and above the main one.
        let left = AINotesGeometry(captureRect: CGRect(x: -1920, y: -200, width: 1920, height: 1080), videoSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(left.videoPoint(forScreenPoint: CGPoint(x: -1920, y: -200)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(left.videoPoint(forScreenPoint: CGPoint(x: -960, y: 340)), CGPoint(x: 960, y: 540))
        XCTAssertNil(left.videoPoint(forScreenPoint: CGPoint(x: 10, y: 10)), "a click on the main display is outside")

        // A selected area somewhere on screen, recorded at 2x.
        let area = AINotesGeometry(captureRect: CGRect(x: 300, y: 120, width: 800, height: 600), videoSize: CGSize(width: 1600, height: 1200))
        XCTAssertEqual(area.videoPoint(forScreenPoint: CGPoint(x: 310, y: 130)), CGPoint(x: 20, y: 20))
        XCTAssertNil(area.videoPoint(forScreenPoint: CGPoint(x: 299, y: 130)), "clicks outside the area are dropped")
        XCTAssertNil(AINotesGeometry(captureRect: .zero, videoSize: CGSize(width: 10, height: 10)).videoPoint(forScreenPoint: .zero))

        XCTAssertEqual(AINotesGeometry.cgPoint(fromAppKit: CGPoint(x: 10, y: 972), primaryDisplayHeight: 982), CGPoint(x: 10, y: 10))
        XCTAssertEqual(AINotesGeometry.cgPoint(fromAppKit: CGPoint(x: -100, y: 1200), primaryDisplayHeight: 982), CGPoint(x: -100, y: -218))
    }

    func testMenuBarShareOfARecording() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(AINotesSession.menuBarFraction(region: display, displayBounds: display, barHeight: 24), 24.0 / 982, accuracy: 1e-9)
        // An area that starts below the menu bar has none of it.
        XCTAssertEqual(AINotesSession.menuBarFraction(region: CGRect(x: 100, y: 200, width: 600, height: 400), displayBounds: display, barHeight: 24), 0)
        // An area that starts halfway down the bar has the rest of it.
        XCTAssertEqual(AINotesSession.menuBarFraction(region: CGRect(x: 0, y: 12, width: 600, height: 120), displayBounds: display, barHeight: 24), 0.1, accuracy: 1e-9)
        // A display above the primary one has a negative origin.
        let upper = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(AINotesSession.menuBarFraction(region: upper, displayBounds: upper, barHeight: 27), 27.0 / 1080, accuracy: 1e-9)
    }

    // MARK: Clock

    func testMediaTimeStartsAtTheFirstFrame() {
        var timeline = AINotesTimeline()
        XCTAssertNil(timeline.mediaTime(forHost: 100), "nothing is in the video before its first frame")
        XCTAssertEqual(timeline.elapsed(atHost: 100), 0)
        timeline.markStart(hostTime: 100)
        timeline.markStart(hostTime: 150)   // only the first frame anchors the clock
        XCTAssertEqual(timeline.mediaTime(forHost: 103.5), 3.5)
        XCTAssertNil(timeline.mediaTime(forHost: 99), "an event from before the first frame is dropped")
    }

    func testPausedTimeIsCutLikeTheVideo() {
        var timeline = AINotesTimeline()
        timeline.markStart(hostTime: 10)
        timeline.pause(hostTime: 15)
        XCTAssertNil(timeline.mediaTime(forHost: 17), "events during a pause are not in the video")
        XCTAssertEqual(timeline.elapsed(atHost: 17), 5, "the video's length holds still while paused")
        timeline.resume(pausedDuration: 4)
        XCTAssertEqual(timeline.mediaTime(forHost: 20), 6)
        timeline.pause(hostTime: 22)
        timeline.resume(pausedDuration: 1)
        XCTAssertEqual(timeline.mediaTime(forHost: 25), 10)
        XCTAssertEqual(timeline.elapsed(atHost: 25), 10)
    }

    func testClockAgreesWithPointerTelemetryAcrossPauses() {
        // The same pause history through both clocks: notes and pointer data
        // must land on the same media times, or clicks drift after a pause.
        var timeline = AINotesTimeline()
        timeline.markStart(hostTime: 50)
        timeline.pause(hostTime: 53)
        timeline.resume(pausedDuration: 2.5)
        let header = CursorTelemetry.Header(sourcePointSize: CGSize(width: 100, height: 100), pixelSize: CGSize(width: 200, height: 200),
                                            frameRate: 30, cursorHiddenInVideo: false, overlaysInTelemetry: false)
        let recording = CursorRecording(header: header, events: [
            .start(time: 50),
            .button(time: 51, button: .left, down: true, x: 0.5, y: 0.5),
            .pause(time: 53),
            .button(time: 54, button: .left, down: true, x: 0.1, y: 0.1),
            .resume(time: 55.5, pausedDuration: 2.5),
            .button(time: 57, button: .left, down: true, x: 0.2, y: 0.2),
        ])
        XCTAssertEqual(recording.clicks.map(\.time), [1, 4.5])
        XCTAssertEqual(timeline.mediaTime(forHost: 57), 4.5)
        var early = AINotesTimeline()
        early.markStart(hostTime: 50)
        XCTAssertEqual(early.mediaTime(forHost: 51), 1)
    }

    func testEventTimestampsShareTheHostClock() {
        // Event timestamps (NSEvent.timestamp, system uptime) are converted with
        // the video's host clock. That only works while the two agree.
        XCTAssertEqual(AINotesClock.hostNow(), ProcessInfo.processInfo.systemUptime, accuracy: 0.05)
    }

    // MARK: Document

    private func sampleDocument() -> AINotesDocument {
        var click = AINoteEvent(kind: .click, time: 11)
        click.videoPoint = AINotePoint(CGPoint(x: 14, y: 8))
        click.name = "Place order"
        var document = AINotesDocument()
        document.generator = "PressShot test"
        document.title = "Take"
        document.recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        document.duration = 12
        document.video = .init(file: "Take.mp4", width: 200, height: 100)
        document.capture = .init(x: 0, y: 0, width: 100, height: 50, menuBar: nil)
        document.narration = .init(status: "transcribed", language: "en_US", detail: nil)
        document.includes = .init(controlNames: true, typing: false)
        document.events = [click]
        document.frames = [AINotesFrame(file: "f01-00m00s-start.jpg", time: 0, reason: "start", width: 200, height: 100, text: "Hello")]
        document.transcript = [AINotesCue(start: 1, end: 2, text: "Hi")]
        return document
    }

    func testDocumentRoundTripsThroughItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pressshot-ai-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = sampleDocument()
        try AINotesLibrary.write(document, to: folder)
        XCTAssertEqual(try AINotesLibrary.read(folder), document)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(files, ["llm.md", "events.json", "transcript.vtt"], "the readable file is llm.md")
    }

    func testDocumentWrittenByAnotherBuildStillOpens() throws {
        // Missing fields, a field of the wrong type, an unknown event kind and
        // an unknown key: everything readable survives.
        let json = """
        {"title": "Old take", "duration": "long", "futureField": 3,
         "video": {"file": "Old take.mp4"},
         "events": [{"kind": "page", "time": 1, "app": "Safari"}, {"kind": "hologram", "time": 2}, {"kind": "click", "time": 3}],
         "frames": [{"file": "a.jpg", "time": 0, "reason": "start", "width": 1, "height": 1}, {"file": 7}]}
        """
        let document = try JSONDecoder().decode(AINotesDocument.self, from: Data(json.utf8))
        XCTAssertEqual(document.title, "Old take")
        XCTAssertEqual(document.duration, 0)
        XCTAssertEqual(document.video.file, "Old take.mp4")
        XCTAssertEqual(document.video.width, 0)
        XCTAssertEqual(document.events.map(\.kind), [.page, .click], "one unreadable event costs that event only")
        XCTAssertEqual(document.frames.map(\.file), ["a.jpg"])
        XCTAssertEqual(document.narration.status, "none")
        XCTAssertTrue(document.transcript.isEmpty)
    }

    func testOptionsFollowTheToolbarToggle() {
        withDefaults([AINotesOptions.enabledKey: false, AINotesOptions.controlNamesKey: nil]) {
            XCTAssertNil(AINotesOptions.current(), "AI notes are off until switched on")
            UserDefaults.standard.set(true, forKey: AINotesOptions.enabledKey)
            XCTAssertEqual(AINotesOptions.current(), AINotesOptions(controlNames: true))
            UserDefaults.standard.set(false, forKey: AINotesOptions.controlNamesKey)
            XCTAssertEqual(AINotesOptions.current(), AINotesOptions(controlNames: false))
        }
    }
}
