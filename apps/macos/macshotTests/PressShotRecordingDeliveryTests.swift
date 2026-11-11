import Cocoa
import XCTest

@MainActor
final class PressShotRecordingDeliveryTests: XCTestCase {
    private var root: URL!
    private var queue: URL { root.appendingPathComponent("queue") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pressshot-recording-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func video() throws -> URL {
        let file = root.appendingPathComponent("synthetic.mp4")
        try Data("synthetic video payload".utf8).write(to: file)
        return file
    }
    func testStopDeliveryOwnsFileBeforeAutomaticUploadAndCopiesOnlyOnSuccess() async throws {
        let source = try video(), expected = try Data(contentsOf: source)
        var complete: PressShotDeliveryCenter.Completion?, requests = 0, copied: [String] = []
        let center = PressShotDeliveryCenter(directory: queue, recordingTransport: { provider, file, done in
            requests += 1; XCTAssertEqual(provider, "wordpress:synthetic")
            XCTAssertNotEqual(file, source); XCTAssertEqual(file.pathExtension, "mp4")
            XCTAssertEqual(try? Data(contentsOf: file), expected)
            complete = done
        }, copyLink: { copied.append($0) })
        let id = try XCTUnwrap(center.submitRecording(file: source, selection: .init(primaryID: "wordpress:synthetic")))
        await MediaExportCoordinator.shared.waitUntilIdle()
        XCTAssertEqual(requests, 1); XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(center.record(id)?.isRecording, true)
        XCTAssertEqual(center.record(id)?.isUploading, true)
        complete?(.success("http://localhost:8930/synthetic.mp4"))
        complete?(.success("http://localhost:8930/duplicate.mp4"))
        XCTAssertEqual(copied, ["http://localhost:8930/synthetic.mp4"])
        XCTAssertEqual(try Data(contentsOf: source), expected)
        center.retry(id); XCTAssertEqual(requests, 1)
    }
    func testFailureKeepsVideoAndRetryUsesTheSamePrimaryAcrossRelaunch() async throws {
        let first = PressShotDeliveryCenter(directory: queue, recordingTransport: { _, _, _ in }, copyLink: { _ in XCTFail("Copied before success") })
        let id = try XCTUnwrap(first.submitRecording(file: video(), selection: .init(primaryID: "original-primary")))
        await MediaExportCoordinator.shared.waitUntilIdle()
        var requested: [String] = [], copied: [String] = []
        let restored = PressShotDeliveryCenter(directory: queue, recordingTransport: { provider, file, done in
            requested.append(provider); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            done(.failure(URLError(.notConnectedToInternet)))
        }, copyLink: { copied.append($0) })
        XCTAssertEqual(restored.record(id)?.statuses["original-primary"], .failed)
        restored.retry(id)
        XCTAssertEqual(requested, ["original-primary"]); XCTAssertTrue(copied.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(restored.fileURL(id)).path))
    }
    func testUnsupportedOrMissingRecordingNeverUploads() throws {
        let center = PressShotDeliveryCenter(directory: queue, recordingTransport: { _, _, _ in XCTFail("Unexpected upload") })
        XCTAssertNil(center.submitRecording(file: root.appendingPathComponent("missing.mp4"), selection: .init(primaryID: "primary")))
        let unsupported = root.appendingPathComponent("synthetic.gif")
        try Data([1]).write(to: unsupported)
        XCTAssertNil(center.submitRecording(file: unsupported, selection: .init(primaryID: "primary")))
    }
    func testNoPrimaryKeepsRecordingWithoutPublishingToAnotherProvider() async throws {
        let center = PressShotDeliveryCenter(directory: queue, recordingTransport: { _, _, _ in XCTFail("Unexpected upload") }, copyLink: { _ in XCTFail("Unexpected clipboard write") })
        let id = try XCTUnwrap(center.submitRecording(file: video(), selection: .init(primaryID: nil)))
        await MediaExportCoordinator.shared.waitUntilIdle()
        XCTAssertFalse(try XCTUnwrap(center.record(id)).isUploading)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(center.fileURL(id)).path))
    }
    func testCompletionDefaultAndExplicitEditorChoiceUseOnePolicy() {
        XCTAssertEqual(PressShotRecordingBehavior.effective("upload", isGIF: false), "upload")
        XCTAssertEqual(PressShotRecordingBehavior.effective("upload", isGIF: true), "editor")
        XCTAssertEqual(PressShotRecordingBehavior.effective("save", isGIF: true), "save")
        XCTAssertEqual(PressShotRecordingBehavior.value("editor"), "editor")
        for (index, value) in PressShotRecordingBehavior.values.enumerated() {
            XCTAssertEqual(PressShotRecordingBehavior.index(value), index)
            XCTAssertEqual(PressShotRecordingBehavior.value(value), value)
        }
        #if OFFLINE
        XCTAssertEqual(PressShotRecordingBehavior.value(nil), "editor")
        XCTAssertFalse(PressShotRecordingBehavior.values.contains("upload"))
        #else
        XCTAssertEqual(PressShotRecordingBehavior.value(nil), "upload")
        XCTAssertEqual(PressShotRecordingBehavior.value("invalid"), "upload")
        #endif
    }
    func testRecordingSettingsPreserveEditorAndCanSelectAutomaticUpload() throws {
        let defaults = UserDefaults.standard, key = "recordingOnStop"
        let before = defaults.object(forKey: key)
        defer { if let before { defaults.set(before, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set("editor", forKey: key)
        let controller = SettingsWindowController()
        defer { controller.close() }
        controller.showTab(id: "recording")
        func popups(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { popups($0) }
        }
        let popup = try XCTUnwrap(popups(XCTUnwrap(controller.window?.contentView)).first { $0.itemTitles == PressShotRecordingBehavior.titles })
        XCTAssertEqual(popup.indexOfSelectedItem, PressShotRecordingBehavior.index("editor"))
        #if !OFFLINE
        popup.selectItem(at: PressShotRecordingBehavior.index("upload"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup))
        XCTAssertEqual(defaults.string(forKey: key), "upload")
        #endif
    }
    func testInvalidFileExtensionInPersistedMetadataIsRejected() throws {
        let value = PressShotDeliveryCenter.Record(id: UUID().uuidString, selection: .init(primaryID: nil))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json["fileExtension"] = "../../private"
        XCTAssertThrowsError(try JSONDecoder().decode(PressShotDeliveryCenter.Record.self, from: JSONSerialization.data(withJSONObject: json)))
        json.removeValue(forKey: "fileExtension")
        XCTAssertEqual(try JSONDecoder().decode(PressShotDeliveryCenter.Record.self, from: JSONSerialization.data(withJSONObject: json)).fileExtension, "png")
    }
}
