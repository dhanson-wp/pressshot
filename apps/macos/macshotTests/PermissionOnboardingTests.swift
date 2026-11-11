import Cocoa
import XCTest

/// After a signing change macOS asks existing users for Screen Recording
/// again; they should see a reassuring "turn it back on" window, not a
/// first-run welcome.
final class PermissionOnboardingTests: XCTestCase {
    @MainActor
    func testDeniedPermissionStopsCaptureBeforeAnyModeIsAccepted() {
        let delegate = CapturePermissionDelegate()
        delegate.permissionGranted = false
        XCTAssertFalse(delegate.canStartCapture)
        XCTAssertEqual(delegate.permissionSetupRequests, 1)
        // Repeated attempts still require permission; they must not mark the
        // capture path ready or start using the own-window-only fallback.
        XCTAssertFalse(delegate.canStartCapture)
        XCTAssertEqual(delegate.permissionSetupRequests, 2)
    }

    @MainActor
    func testGrantedPermissionAllowsCaptureAndRevocationBlocksTheNextAttempt() {
        let delegate = CapturePermissionDelegate()
        delegate.permissionGranted = true
        XCTAssertTrue(delegate.canStartCapture)
        XCTAssertEqual(delegate.permissionSetupRequests, 0)
        delegate.permissionGranted = false
        XCTAssertFalse(delegate.canStartCapture)
        XCTAssertEqual(delegate.permissionSetupRequests, 1)
    }

    func testReturningUserDetection() {
        withDefaults(["SUHasLaunchedBefore": nil, "screenRecordingGrantedBefore": nil]) {
            XCTAssertFalse(PermissionOnboardingController.isReturningUser())
        }
        withDefaults(["SUHasLaunchedBefore": true, "screenRecordingGrantedBefore": nil]) {
            XCTAssertTrue(PermissionOnboardingController.isReturningUser())
        }
        withDefaults(["SUHasLaunchedBefore": nil, "screenRecordingGrantedBefore": nil]) {
            PermissionOnboardingController.rememberGranted()
            XCTAssertTrue(PermissionOnboardingController.isReturningUser())
        }
    }

    func testReturningWindowFitsTheNoteAboveTheGuide() throws {
        for returning in [false, true] {
            let controller = PermissionOnboardingController(returningUser: returning)
            controller.window?.appearance = NSAppearance(named: .aqua)
            let content = try XCTUnwrap(controller.window?.contentView)
            content.layoutSubtreeIfNeeded()
            let labels = content.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
            let note = labels.first { $0.stringValue.hasPrefix(L("After some updates, macOS asks you to allow macshot again.")) }
            XCTAssertEqual(note != nil, returning)
            if let note {
                let images = content.subviews.compactMap { $0 as? NSImageView }
                let guide = try XCTUnwrap(images.max { $0.frame.width < $1.frame.width })
                XCTAssertGreaterThanOrEqual(note.frame.minY, guide.frame.maxY, "note overlaps the guide image")
                XCTAssertGreaterThan(note.frame.height, 30, "note should wrap onto several lines")
            }
            for view in content.subviews where !view.isHidden {
                XCTAssertTrue(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.frame), "\(view) is clipped")
            }
            if returning {
                let png = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                if let png { content.cacheDisplay(in: content.bounds, to: png)
                    try? png.representation(using: .png, properties: [:])?
                        .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-returning.png")) }
            }
            controller.close()
        }
    }
}

@MainActor
private final class CapturePermissionDelegate: AppDelegate {
    var permissionGranted = false
    var permissionSetupRequests = 0
    override var hasScreenRecordingPermission: Bool { permissionGranted }
    override func showOnboarding() { permissionSetupRequests += 1 }
}
