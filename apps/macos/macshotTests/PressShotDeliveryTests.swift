import Cocoa
import XCTest

@MainActor
final class PressShotDeliveryTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pressshot-delivery-tests/" + UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    private func image() -> NSImage {
        ImageProbe.makeImage(width: 32, height: 24) { context in
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }
    func testCleanupDoesNotClaimMacShotOrOtherApplicationsFiles() {
        for name in ["macshot_upload_old.tmp", "macshot_mic_audio.m4a", "Recording yesterday.mp4", "pressshot-clipboard.png", "pressshot-clipboard-recording.mp4", UUID().uuidString + ".gif"] {
            XCTAssertFalse(LaunchCleanup.ownsTemporaryFilename(name), name)
        }
        XCTAssertTrue(LaunchCleanup.ownsTemporaryFilename("pressshot_upload_owned.tmp"))
    }
    func testPrimaryCannotBeDeselectedAndSecondaryIsCaptureScoped() {
        var selection = PressShotDestinationSelection(primaryID: "primary")
        selection.setSelected(false, id: "primary")
        selection.setSelected(true, id: "secondary")
        XCTAssertEqual(selection.selectedIDs, ["primary", "secondary"])
        XCTAssertEqual(PressShotDestinationSelection(primaryID: "primary").selectedIDs, ["primary"])
    }
    func testSecondarySuccessNeverSubstitutesForPrimaryAndRetrySkipsCompleted() async throws {
        var pending: [String: PressShotDeliveryCenter.Completion] = [:]
        var requested: [String] = [], copied: [String] = []
        let center = PressShotDeliveryCenter(directory: directory, transport: { provider, _, completion in
            requested.append(provider); pending[provider] = completion
        }, copyLink: { copied.append($0) })
        let id = try XCTUnwrap(center.submit(image: image(), selection: .init(primaryID: "primary", additionalIDs: ["secondary"])))
        await MediaExportCoordinator.shared.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(center.fileURL(id)).path))
        pending["secondary"]?(.success("https://secondary.example/capture"))
        pending["primary"]?(.failure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(center.record(id)?.statuses["secondary"], .uploaded)
        center.retry(id)
        XCTAssertEqual(requested.filter { $0 == "secondary" }.count, 1)
        XCTAssertEqual(requested.filter { $0 == "primary" }.count, 2)
        pending["primary"]?(.success("https://primary.example/capture"))
        pending["primary"]?(.success("https://primary.example/duplicate-callback"))
        XCTAssertEqual(copied, ["https://primary.example/capture"])
        center.retry(id)
        XCTAssertEqual(requested.count, 3)
    }
    func testPrimaryCopiesBeforeSecondaryCompletesAndAdditionalUploadKeepsLink() async throws {
        var pending: [String: PressShotDeliveryCenter.Completion] = [:], copied: [String] = []
        let center = PressShotDeliveryCenter(directory: directory, transport: { provider, _, done in pending[provider] = done }, copyLink: { copied.append($0) })
        let id = try XCTUnwrap(center.submit(image: image(), selection: .init(primaryID: "primary", additionalIDs: ["secondary"])))
        await MediaExportCoordinator.shared.waitUntilIdle()
        pending["primary"]?(.success("https://primary.example/capture"))
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(center.record(id)?.isUploading, true)
        pending["secondary"]?(.success("https://secondary.example/capture"))
        center.addDestinations(["third", "primary"], to: id)
        XCTAssertEqual(center.record(id)?.statuses["primary"], .uploaded)
        XCTAssertEqual(center.record(id)?.statuses["third"], .uploading)
        pending["third"]?(.success("https://third.example/capture"))
        XCTAssertEqual(copied, ["https://primary.example/capture"])
    }
    func testInterruptedUploadRestoresLocalFileAndRetriesOnlyUnfinishedDestination() async throws {
        let first = PressShotDeliveryCenter(directory: directory, transport: { _, _, _ in }, copyLink: { _ in XCTFail("Unexpected clipboard write") })
        let id = try XCTUnwrap(first.submit(image: image(), selection: .init(primaryID: "primary", additionalIDs: ["secondary"])))
        await MediaExportCoordinator.shared.waitUntilIdle()
        first.associateHistory("synthetic-history", with: id)
        first.finish(id, destination: "secondary", result: .success("https://secondary.example/capture"))
        var requested: [String] = []
        let restored = PressShotDeliveryCenter(directory: directory, transport: { id, _, done in
            requested.append(id); done(.failure(URLError(.notConnectedToInternet)))
        }, copyLink: { _ in XCTFail("Unexpected clipboard write") })
        XCTAssertEqual(restored.record(id)?.historyEntryID, "synthetic-history")
        XCTAssertEqual(restored.record(id)?.statuses["primary"], .failed)
        XCTAssertEqual(restored.record(id)?.statuses["secondary"], .uploaded)
        restored.retry(id)
        XCTAssertEqual(requested, ["primary"])
        XCTAssertNotNil(NSImage(contentsOf: try XCTUnwrap(restored.fileURL(id))))
    }
    func testNoConnectionSavesLocallyWithoutTransportOrClipboard() async throws {
        let center = PressShotDeliveryCenter(directory: directory, transport: { _, _, _ in XCTFail("Must not upload") }, copyLink: { _ in XCTFail("Must not copy") })
        let id = try XCTUnwrap(center.submit(image: image(), selection: .init(primaryID: nil)))
        await MediaExportCoordinator.shared.waitUntilIdle()
        XCTAssertEqual(center.record(id)?.isUploading, false)
        XCTAssertNotNil(NSImage(contentsOf: try XCTUnwrap(center.fileURL(id))))
    }
    func testInvalidProviderLinkFailsWithoutChangingClipboard() async throws {
        let center = PressShotDeliveryCenter(directory: directory, transport: { _, _, done in done(.success("file:///private/capture.png")) }, copyLink: { _ in XCTFail("Invalid link copied") })
        let id = try XCTUnwrap(center.submit(image: image(), selection: .init(primaryID: "primary")))
        await MediaExportCoordinator.shared.waitUntilIdle()
        XCTAssertEqual(center.record(id)?.statuses["primary"], .failed)
        XCTAssertNil(center.record(id)?.primaryLink)
    }
    func testFailedLocalSaveNeverStartsAnUpload() async throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic obstruction".utf8).write(to: directory)
        let center = PressShotDeliveryCenter(directory: directory, transport: { _, _, _ in XCTFail("Must not upload unsaved pixels") }, copyLink: { _ in XCTFail("Must not copy") })
        let id = try XCTUnwrap(center.submit(image: image(), selection: .init(primaryID: "primary")))
        await MediaExportCoordinator.shared.waitUntilIdle()
        XCTAssertEqual(center.record(id)?.isUploading, false)
        XCTAssertNil(center.record(id)?.primaryLink)
    }
}
