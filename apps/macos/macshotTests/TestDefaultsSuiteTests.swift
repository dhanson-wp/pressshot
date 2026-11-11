import XCTest

/// Throwaway defaults suites must not pile up in ~/Library/Preferences: each
/// one used to leave an empty plist behind after its test finished.
final class TestDefaultsSuiteTests: XCTestCase {

    func testRemoveEmptiesTheSuiteAndDeletesItsFile() throws {
        let suite = TestDefaultsSuite.uniqueName("cleanup")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("value", forKey: "key")
        CFPreferencesAppSynchronize(suite as CFString)
        let file = TestDefaultsSuite.fileURL(for: suite)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the suite should have reached disk")

        TestDefaultsSuite.remove(defaults, named: suite)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(defaults.object(forKey: "key"))
    }

    /// `scripts/run-tests.sh` sweeps by this prefix; a suite named any other
    /// way would be left behind.
    func testUniqueNamesCarryTheSweptPrefix() {
        let first = TestDefaultsSuite.uniqueName("example")
        let second = TestDefaultsSuite.uniqueName("example")
        XCTAssertTrue(first.hasPrefix("pressshot-test-suite-example-"))
        XCTAssertNotEqual(first, second)
    }
}
