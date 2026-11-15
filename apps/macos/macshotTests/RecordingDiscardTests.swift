import Cocoa
import XCTest

/// The recording bar's trash button and Esc throw a take away: no file is
/// delivered and no failure is shown, so nothing is saved, uploaded, copied
/// or added to history.
@MainActor
final class RecordingDiscardTests: XCTestCase {

    func testATakeCanBeDiscardedWhileStartingRecordingPausedOrStopping() {
        XCTAssertFalse(RecordingEngine.canDiscard(.idle))
        for state: RecordingEngine.State in [.preparing, .recording, .paused, .stopping] {
            XCTAssertTrue(RecordingEngine.canDiscard(state), "\(state)")
        }
    }

    func testADiscardedTakeReportsNoFileAndNoFailure() {
        let url = URL(fileURLWithPath: "/tmp/take.mp4")
        let result = RecordingEngine.completionResult(url: url, error: CocoaError(.fileWriteOutOfSpace), discarded: true)
        XCTAssertNil(result.url)
        XCTAssertNil(result.error)
    }

    func testAKeptTakeReportsItsFileAndFailureUnchanged() {
        let url = URL(fileURLWithPath: "/tmp/take.mp4")
        let result = RecordingEngine.completionResult(url: url, error: CocoaError(.fileWriteOutOfSpace), discarded: false)
        XCTAssertEqual(result.url, url)
        XCTAssertEqual((result.error as? CocoaError)?.code, .fileWriteOutOfSpace)
        XCTAssertNil(RecordingEngine.completionResult(url: url, error: nil, discarded: false).error)
    }

    func testDiscardingWithNoTakeDoesNothing() {
        let engine = RecordingEngine()
        var completions = 0
        engine.onCompletion = { _, _ in completions += 1 }
        engine.discardRecording()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(completions, 0)
    }

    func testTheEscKeyIdNeverCollidesWithAShortcutSetting() {
        for key in [HotkeyManager.TransientKey.discardRecording] {
            XCTAssertNil(HotkeyManager.HotkeySlot(rawValue: Int(key.rawValue)))
        }
    }

    func testDiscardingWhileStartingReportsNothingInsteadOfAFailure() async throws {
        // The fake display is never queried: the discard lands before setup's
        // first turn, the same way an immediate stop does.
        let config = try RecordingConfiguration(displayID: UInt32.max,
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            backingScale: 1, frameRate: 30, microphone: false, systemAudio: false,
            microphoneDeviceID: nil, excludedWindows: [], filename: "unused")
        let engine = RecordingEngine()
        let completed = expectation(description: "discarded take completes once")
        completed.assertForOverFulfill = true
        engine.onCompletion = { url, error in
            XCTAssertNil(url)
            XCTAssertNil(error, "a discarded take must not show \"Recording failed\"")
            completed.fulfill()
        }
        engine.startRecording(configuration: config)
        XCTAssertEqual(engine.state, .preparing)
        engine.discardRecording()
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(engine.state, .idle)

        // The next take is an ordinary one again: a stop still reports why.
        let stopped = expectation(description: "next take reports its stop")
        engine.onCompletion = { _, error in
            XCTAssertNotNil(error)
            stopped.fulfill()
        }
        engine.startRecording(configuration: config)
        engine.stopRecording()
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testTheRecordingBarHasATrashButtonThatAsksToDiscard() throws {
        let hud = RecordingHUDPanel()
        hud.update(elapsedSeconds: 0)
        var discards = 0, stops = 0
        hud.onDiscardRecording = { discards += 1 }
        hud.onStopRecording = { stops += 1 }
        let buttons = (hud.contentView?.subviews ?? []).compactMap { $0 as? NSButton }
        let trash = try XCTUnwrap(buttons.first { $0.image?.accessibilityDescription == L("Discard Recording") })
        XCTAssertTrue(trash.toolTip?.contains("Esc") ?? false)
        trash.performClick(nil)
        XCTAssertEqual(discards, 1)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(hud.frame.width, RecordingHUDPanel.panelWidth)
        // Nothing overlaps: stop, pause and trash sit side by side.
        let frames = buttons.map(\.frame).sorted { $0.minX < $1.minX }
        for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertLessThanOrEqual(a.maxX, b.minX) }
        hud.close()
    }

    /// The question box must sit above the bar, the recording overlays, and
    /// floating windows of the recorded app, or it hides behind them.
    func testTheDiscardQuestionSitsAboveEverythingOnScreen() {
        let hud = RecordingHUDPanel()
        XCTAssertEqual(hud.level, RecordingHUDPanel.hudLevel)
        let alertLevel = RecordingHUDPanel.discardAlertLevel
        XCTAssertGreaterThan(alertLevel.rawValue, hud.level.rawValue)
        for below in [NSWindow.Level.floating, .modalPanel, .statusBar] {
            XCTAssertGreaterThan(alertLevel.rawValue, below.rawValue)
        }
        // Still under the screen saver and the system's own top windows.
        XCTAssertLessThan(alertLevel.rawValue, NSWindow.Level.screenSaver.rawValue)
        hud.close()
    }
}
