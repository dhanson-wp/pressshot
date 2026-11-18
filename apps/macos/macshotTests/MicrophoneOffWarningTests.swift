import XCTest

final class MicrophoneOffWarningTests: XCTestCase {
    @MainActor
    func testWarnsOnlyWhenMicrophoneIsOffAndNotSuppressed() {
        let cases: [(mic: Bool?, suppressed: Bool?, warns: Bool)] = [
            (nil, nil, true),
            (false, nil, true),
            (false, false, true),
            (false, true, false),
            (true, nil, false),
            (true, true, false),
        ]
        for c in cases {
            withDefaults(["recordMicAudio": c.mic, MicrophoneOffWarning.suppressedKey: c.suppressed]) {
                XCTAssertEqual(MicrophoneOffWarning.shouldWarn(), c.warns, "mic: \(String(describing: c.mic)), suppressed: \(String(describing: c.suppressed))")
            }
        }
    }
}
