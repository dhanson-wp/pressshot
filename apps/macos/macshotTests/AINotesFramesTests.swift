import CoreGraphics
import ImageIO
import XCTest

/// Choosing and storing the key frames of a recording.
final class AINotesFramesTests: XCTestCase {

    private func grid(_ fill: (Int) -> UInt8) -> AINotesLumaGrid {
        AINotesLumaGrid(samples: (0..<(AINotesLumaGrid.columns * AINotesLumaGrid.rows)).map(fill))
    }

    private func image(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        return try XCTUnwrap(context.makeImage())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pressshot-ai-frames-\(UUID().uuidString)")
    }

    func testDistanceIsTheShareOfCellsThatChanged() {
        let black = grid { _ in 0 }
        XCTAssertEqual(black.distance(to: black), 0)
        XCTAssertEqual(black.distance(to: grid { _ in 255 }), 1)
        XCTAssertEqual(black.distance(to: grid { $0 % 2 == 0 ? 0 : 255 }), 0.5)
        XCTAssertEqual(black.distance(to: grid { _ in 6 }), 0, "small brightness shifts are ignored")
        XCTAssertEqual(black.distance(to: AINotesLumaGrid(samples: [1, 2])), 1, "grids of different sizes never match")
    }

    func testGridReadsAnImage() throws {
        let dark = try XCTUnwrap(AINotesLumaGrid(cgImage: image(gray: 0)))
        let light = try XCTUnwrap(AINotesLumaGrid(cgImage: image(gray: 1)))
        XCTAssertEqual(dark.distance(to: light), 1)
        XCTAssertEqual(dark.distance(to: try XCTUnwrap(AINotesLumaGrid(cgImage: image(gray: 0)))), 0)
    }

    func testTheLeastDistinctiveFrameIsDroppedFirst() {
        let black = grid { _ in 0 }, white = grid { _ in 255 }
        let half = grid { $0 % 2 == 0 ? 0 : 255 }, nearlyBlack = grid { $0 < 10 ? 255 : 0 }
        XCTAssertEqual(AINotesFrameStore.victim([(1, white), (1, black), (1, nearlyBlack), (1, half), (1, white)]), 1)
        XCTAssertEqual(AINotesFrameStore.victim([(1, black), (1, black), (1, white)]), 1, "the first frame is never dropped")
        XCTAssertNil(AINotesFrameStore.victim([(1, black), (1, white)]), "two frames are always kept")
        XCTAssertEqual(AINotesFrameStore.victim([(1, white), (3, black), (1, black), (1, white)]), 2,
                       "a click frame outlasts an equally redundant screen-change frame")
    }

    func testStoreStaysWithinBudgetOnDisk() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AINotesFrameStore(directory: directory)
        var stored: [URL] = []
        store.onStore = { stored.append($0) }
        let total = AINotesFrameStore.maximumFrames + 15
        for index in 0..<total {
            // Every third frame repeats its neighbour, so there is something redundant to drop.
            let lit = (index - (index % 3 == 2 ? 1 : 0)) * 40
            store.add(try image(gray: CGFloat(index) / CGFloat(total)), id: index, time: Double(index) * 2,
                      reason: index == 0 ? .start : .screen, grid: grid { $0 < lit ? 255 : 0 })
        }
        XCTAssertEqual(stored.count, total, "every stored frame is announced, for reading its text early")
        XCTAssertEqual(store.entries.count, AINotesFrameStore.maximumFrames)
        XCTAssertEqual(store.entries.first?.id, 0, "the first frame survives the budget")
        XCTAssertEqual(store.entries.last?.id, total - 1, "the last frame survives the budget")
        let grids = store.entries.map(\.grid)
        XCTAssertLessThanOrEqual(zip(grids, grids.dropFirst()).filter { $0.distance(to: $1) == 0 }.count, 3, "duplicates go first")

        let result = store.finalize()
        XCTAssertEqual(result.frames.count, AINotesFrameStore.maximumFrames)
        XCTAssertEqual(result.frames.first?.file, "f01-00m00s-start.jpg", "frames are named by order, time and reason")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, AINotesFrameStore.maximumFrames,
                       "dropped frames are removed from disk")
        XCTAssertEqual(Set(result.sources.keys), Set(result.frames.map(\.file)))
    }

    func testClickFramesKeepTheirRingAndBeforeFrame() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AINotesFrameStore(directory: directory)
        let ring = CGPoint(x: 0.25, y: 0.75)
        store.add(try image(gray: 0), id: 1, time: 0, reason: .start, grid: grid { _ in 0 })
        store.add(try image(gray: 0.2), id: 3, time: 65, reason: .beforeClick, grid: grid { $0 < 500 ? 255 : 0 }, owner: 2, ring: ring)
        store.add(try image(gray: 1), id: 2, time: 65.15, reason: .click, grid: grid { _ in 255 }, ring: ring)

        // The same picture with the same mark is stored once; a different mark is a different frame.
        XCTAssertEqual(store.match(grid { _ in 255 }, ring: ring)?.id, 2)
        XCTAssertNil(store.match(grid { _ in 255 }, ring: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertNil(store.match(grid { _ in 255 }, ring: nil))
        store.alias(9, to: 2)
        store.aliasBefore(of: 9, to: 3)

        let result = store.finalize()
        XCTAssertEqual(result.frames.map(\.file), ["f01-00m00s-start.jpg", "f02-01m05s-before-click.jpg", "f03-01m05s-click.jpg"])
        XCTAssertEqual(result.files[2], "f03-01m05s-click.jpg")
        XCTAssertEqual(result.beforeFiles[2], "f02-01m05s-before-click.jpg")
        XCTAssertEqual(result.files[9], "f03-01m05s-click.jpg", "a repeated click points at the frame already stored")
        XCTAssertEqual(result.beforeFiles[9], "f02-01m05s-before-click.jpg")
        XCTAssertEqual(result.rings["f03-01m05s-click.jpg"], ring)
        XCTAssertNil(result.rings["f01-00m00s-start.jpg"])
    }

    func testFinishingAFrameCoversSecretsAndKeepsItReadable() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("frame.jpg")
        XCTAssertTrue(AINotesFrameEncoder.writeJPEG(try image(gray: 1), to: url, quality: 0.92))
        // Cover the top-left quarter; mark a click in the bottom-right.
        AINotesFrameEncoder.finish(frameAt: url, ring: CGPoint(x: 0.8, y: 0.8), covering: [CGRect(x: 0, y: 0, width: 0.4, height: 0.4)])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let finished = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(finished.width, 64)
        let after = try XCTUnwrap(AINotesLumaGrid(cgImage: finished))
        let columns = AINotesLumaGrid.columns
        XCTAssertLessThan(after.samples[2 * columns + 4], 80, "the covered corner is dark")
        XCTAssertGreaterThan(after.samples[18 * columns + 10], 200, "the rest of the frame is untouched")
    }
}
