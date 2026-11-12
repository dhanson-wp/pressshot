import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// The screen's brightness averaged over a coarse grid of cells, used to tell how much of it
/// changed. Averages rather than single pixels, so a line of text appearing (an error message)
/// moves the cells it covers while the pointer passing through barely registers.
nonisolated struct AINotesLumaGrid: Equatable, Sendable {
    static let columns = 64
    static let rows = 36

    var samples: [UInt8]

    init(samples: [UInt8]) {
        self.samples = samples
    }

    init?(pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0,
              let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var samples = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        // About 8 by 8 readings per cell: enough to catch thin text, cheap enough for twice a second.
        let stepX = max(width / (Self.columns * 8), 1)
        let stepY = max(height / (Self.rows * 8), 1)
        for row in 0..<Self.rows {
            let top = row * height / Self.rows, bottom = max((row + 1) * height / Self.rows, top + 1)
            for column in 0..<Self.columns {
                let left = column * width / Self.columns, right = max((column + 1) * width / Self.columns, left + 1)
                var sum = 0, count = 0
                var y = top
                while y < bottom {
                    let line = bytes + y * rowBytes
                    var x = left
                    while x < right {
                        if planar {
                            sum += Int(line[x])                                              // the luma plane
                        } else {
                            let pixel = line + x * 4                                         // BGRA
                            sum += (Int(pixel[0]) * 29 + Int(pixel[1]) * 150 + Int(pixel[2]) * 77) >> 8
                        }
                        count += 1
                        x += stepX
                    }
                    y += stepY
                }
                samples[row * Self.columns + column] = UInt8(sum / max(count, 1))
            }
        }
        self.samples = samples
    }

    init?(cgImage: CGImage) {
        var samples = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        let drawn: Bool = samples.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: Self.columns, height: Self.rows, bitsPerComponent: 8,
                                          bytesPerRow: Self.columns, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium   // averages, like the pixel-buffer path
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: Self.columns, height: Self.rows))
            return true
        }
        guard drawn else { return nil }
        self.samples = samples
    }

    /// Fraction of cells that differ noticeably, 0...1. For scale: a line of text across half the
    /// screen is about 0.01, a menu opening 0.03, a new page most of 1.
    func distance(to other: AINotesLumaGrid) -> Double {
        guard samples.count == other.samples.count, !samples.isEmpty else { return 1 }
        var changed = 0
        for index in samples.indices where abs(Int(samples[index]) - Int(other.samples[index])) > 8 {
            changed += 1
        }
        return Double(changed) / Double(samples.count)
    }
}

/// Scales frames for model vision, marks clicks, writes JPEGs.
nonisolated enum AINotesFrameEncoder {
    /// About the largest size a vision model reads without downscaling it again.
    static let longEdge: CGFloat = 1568

    static func image(from pixelBuffer: CVPixelBuffer, context: CIContext) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, longEdge / max(image.extent.width, image.extent.height))
        if scale < 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        let extent = image.extent.integral
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func scaled(_ image: CGImage) -> CGImage? {
        let scale = min(1, longEdge / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        return redraw(image, width: Int(CGFloat(image.width) * scale), height: Int(CGFloat(image.height) * scale)) { _ in }
    }

    /// Draws a ring at `point`, given as a fraction of the frame from its top-left corner.
    static func ring(on image: CGImage, at point: CGPoint) -> CGImage? {
        redraw(image, width: image.width, height: image.height) { context in
            let center = CGPoint(x: point.x * CGFloat(image.width), y: (1 - point.y) * CGFloat(image.height))
            let radius = max(CGFloat(max(image.width, image.height)) / 70, 14)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
            context.setLineWidth(radius / 2.4)
            context.strokeEllipse(in: circle)
            context.setStrokeColor(CGColor(red: 1, green: 0.16, blue: 0.2, alpha: 1))
            context.setLineWidth(radius / 4.5)
            context.strokeEllipse(in: circle)
        }
    }

    private static func redraw(_ image: CGImage, width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        body(context)
        return context.makeImage()
    }

    static let quality = 0.62

    /// Finishes a stored frame once its text has been read: blacks out the places where a secret
    /// was recognised (redacting the text alone would leave it readable in the picture), marks the
    /// click, and writes the frame at its final quality. Rectangles and the point are fractions of
    /// the frame from its top-left corner.
    static func finish(frameAt url: URL, ring point: CGPoint?, covering secrets: [CGRect]) {
        guard point != nil || !secrets.isEmpty,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        if !secrets.isEmpty {
            let width = CGFloat(image.width), height = CGFloat(image.height)
            guard let covered = redraw(image, width: image.width, height: image.height, { context in
                context.setFillColor(CGColor(gray: 0.12, alpha: 1))
                for box in secrets {
                    let rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
                    context.fill(rect.insetBy(dx: -4, dy: -3))
                }
            }) else { return }
            image = covered
        }
        if let point, let marked = ring(on: image, at: point) { image = marked }
        writeJPEG(image, to: url)
    }

    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = AINotesFrameEncoder.quality) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

/// Holds the frames of one recording on disk and keeps them within budget.
nonisolated final class AINotesFrameStore {
    struct Entry {
        var id: Int
        var time: Double
        var reason: AINotesFrameSink.Reason
        var url: URL
        var grid: AINotesLumaGrid
        var width: Int
        var height: Int
        /// For a "before" frame, the click it belongs to.
        var owner: Int?
        /// Where to mark a click, as a fraction of the frame from its top-left.
        var ring: CGPoint?
    }

    struct Result {
        var frames: [AINotesFrame] = []
        /// Request ID to file name, for frames that were kept.
        var files: [Int: String] = [:]
        var beforeFiles: [Int: String] = [:]
        /// Frames that still need their click ring drawn, by file name. The ring goes on after
        /// text recognition, so it never hides the label that was clicked.
        var rings: [String: CGPoint] = [:]
        /// Where each frame's file was before it got its final name, for matching up text read early.
        var sources: [String: URL] = [:]
    }

    static let maximumFrames = 40

    let directory: URL
    /// Called with the path of each frame as it is written.
    var onStore: ((URL) -> Void)?
    private(set) var entries: [Entry] = []
    private var counter = 0
    /// Requests answered by a frame that already existed.
    private var aliases: [Int: Int] = [:]
    private var beforeAliases: [Int: Int] = [:]

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var lastGrid: AINotesLumaGrid? { entries.last?.grid }

    /// Points a request at an existing frame instead of storing the same picture twice.
    func alias(_ id: Int, to existing: Int) {
        aliases[id] = existing
    }

    /// The same, for the "before" frame of a click.
    func aliasBefore(of owner: Int, to existing: Int) {
        beforeAliases[owner] = existing
    }

    /// A recent frame that already shows this picture with the same click mark. Clicking the same
    /// thing open and shut produces the same two pictures over and over; each is stored once.
    func match(_ grid: AINotesLumaGrid, ring: CGPoint?) -> Entry? {
        entries.suffix(10).last { entry in
            let sameRing: Bool
            switch (entry.ring, ring) {
            case (nil, nil): sameRing = true
            case let (a?, b?): sameRing = abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
            default: sameRing = false
            }
            return sameRing && entry.grid.distance(to: grid) < 0.003
        }
    }

    func add(_ image: CGImage, id: Int, time: Double, reason: AINotesFrameSink.Reason, grid: AINotesLumaGrid, owner: Int? = nil, ring: CGPoint? = nil) {
        counter += 1
        let url = directory.appendingPathComponent(String(format: ".pending-%04d.jpg", counter))
        // A frame that will be re-encoded with its ring is stored nearly lossless until then.
        guard AINotesFrameEncoder.writeJPEG(image, to: url, quality: ring == nil ? AINotesFrameEncoder.quality : 0.92) else { return }
        let entry = Entry(id: id, time: time, reason: reason, url: url, grid: grid, width: image.width, height: image.height, owner: owner, ring: ring)
        let index = entries.firstIndex { $0.time > time } ?? entries.count
        entries.insert(entry, at: index)
        onStore?(url)
        while entries.count > Self.maximumFrames,
              let victim = Self.victim(entries.map { (weight: $0.reason.weight, grid: $0.grid) }) {
            try? FileManager.default.removeItem(at: entries[victim].url)
            entries.remove(at: victim)
        }
    }

    /// The frame that adds least: closest to a neighbour in time, weighted by why it was taken.
    /// The first and last frames are never chosen.
    static func victim(_ frames: [(weight: Double, grid: AINotesLumaGrid)]) -> Int? {
        guard frames.count > 2 else { return nil }
        var best: (index: Int, score: Double)?
        for index in 1..<(frames.count - 1) {
            let nearest = min(frames[index].grid.distance(to: frames[index - 1].grid),
                              frames[index].grid.distance(to: frames[index + 1].grid))
            let score = (nearest + 0.01) * frames[index].weight
            if best == nil || score < best!.score { best = (index, score) }
        }
        return best?.index
    }

    /// Gives the frames their final names (`f01-00m04s-click.jpg`) in time order.
    func finalize() -> Result {
        var result = Result()
        var names: [Int: String] = [:]
        for (index, entry) in entries.enumerated() {
            let seconds = Int(max(entry.time, 0))
            let name = String(format: "f%02d-%02dm%02ds-%@.jpg", index + 1, seconds / 60, seconds % 60, entry.reason.rawValue)
            do {
                try FileManager.default.moveItem(at: entry.url, to: directory.appendingPathComponent(name))
            } catch {
                continue
            }
            result.frames.append(AINotesFrame(file: name, time: max(entry.time, 0), reason: entry.reason.rawValue,
                                          width: entry.width, height: entry.height))
            names[entry.id] = name
            result.sources[name] = entry.url
            if let ring = entry.ring { result.rings[name] = ring }
            if let owner = entry.owner {
                result.beforeFiles[owner] = name
            } else {
                result.files[entry.id] = name
            }
        }
        for (id, existing) in aliases {
            if let name = names[existing] { result.files[id] = name }
        }
        for (owner, existing) in beforeAliases {
            if let name = names[existing] { result.beforeFiles[owner] = name }
        }
        entries = []
        return result
    }
}

/// Picks the few frames worth keeping while a recording runs. The capture queue only hands over
/// a reference to the newest screen frame; scaling and JPEG encoding happen on a utility queue so
/// recording never stalls. Times are media times from the shared clock, so a pause in the
/// recording leaves no gap between a frame's name and its place in the video.
nonisolated final class AINotesFrameSink: @unchecked Sendable {
    enum Reason: String {
        case start, click, beforeClick = "before-click", page, screen, end

        var weight: Double {
            switch self {
            case .click: return 3
            case .page: return 2.5
            case .beforeClick: return 1.5
            default: return 1
            }
        }
    }

    private let clock: AINotesClock
    private let videoSize: CGSize
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    /// False while the recording is paused: those frames are not in the video.
    private var accepting = true
    private var nextID = 0
    private var lastClick: (id: Int, time: Double)?

    // Work-queue state.
    private let work = DispatchQueue(label: "com.derekhanson.pressshot.ai-notes.frames", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let store: AINotesFrameStore
    private var timer: DispatchSourceTimer?
    private var paused = false
    private var finished = false
    private var tookStart = false
    private var previousGrid: AINotesLumaGrid?
    private var changedSince: Double?
    private var lastScreenFrame = -10.0
    /// Seconds between frames taken without any input. Grows while the screen keeps changing by
    /// itself (a video playing), so that cannot use up the budget; input resets it.
    private var screenCooldown = AINotesFrameSink.minimumCooldown
    private static let minimumCooldown = 2.0

    init(directory: URL, clock: AINotesClock, videoSize: CGSize, onStore: ((URL) -> Void)? = nil) throws {
        self.clock = clock
        self.videoSize = videoSize
        store = try AINotesFrameStore(directory: directory)
        store.onStore = onStore
    }

    /// Capture queue: remember the newest raw screen frame. Nothing else happens here.
    func update(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        if accepting { latest = pixelBuffer }
        lock.unlock()
    }

    private func snapshot() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private func makeID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    func start() {
        work.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: work)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.5, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
            self.timer = timer
        }
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        accepting = !paused
        lock.unlock()
        work.async { [self] in
            self.paused = paused
            changedSince = nil
            previousGrid = nil
        }
    }

    /// Asks for a frame `delay` seconds from now. With `minimumChange`, the frame is kept only if
    /// that fraction of the screen differs from the last kept frame. Returns an ID to look the file up by.
    func request(_ reason: Reason, time: Double, delay: Double = 0, minimumChange: Double = 0) -> Int {
        let id = makeID()
        work.asyncAfter(deadline: .now() + delay) { [self] in
            screenCooldown = Self.minimumCooldown
            capture(id: id, reason: reason, time: time + delay, minimumChange: minimumChange)
        }
        return id
    }

    /// A click at `point` (video pixels). The frame is taken a moment later so the result of the
    /// click shows; when the click changed a lot, the frame from before it is kept as well.
    func requestClick(time: Double, at point: CGPoint) -> Int {
        lock.lock()
        if let lastClick, time - lastClick.time < 0.35 {   // second half of a double-click
            lock.unlock()
            return lastClick.id
        }
        nextID += 1
        let id = nextID
        lastClick = (id, time)
        lock.unlock()

        let ring = CGPoint(x: point.x / max(videoSize.width, 1), y: point.y / max(videoSize.height, 1))
        work.async { [self] in
            guard !paused, !finished else { return }
            screenCooldown = Self.minimumCooldown
            var before: (image: CGImage, grid: AINotesLumaGrid)?
            if let buffer = snapshot(), let grid = AINotesLumaGrid(pixelBuffer: buffer),
               let image = AINotesFrameEncoder.image(from: buffer, context: context) {
                before = (image, grid)
            }
            work.asyncAfter(deadline: .now() + 0.15) { [self] in
                guard !paused, !finished, let buffer = snapshot(), let grid = AINotesLumaGrid(pixelBuffer: buffer),
                      let image = AINotesFrameEncoder.image(from: buffer, context: context) else { return }
                if let before, before.grid.distance(to: grid) >= 0.05 {
                    if let same = store.match(before.grid, ring: ring) {
                        store.aliasBefore(of: id, to: same.id)
                    } else {
                        store.add(before.image, id: makeID(), time: time, reason: .beforeClick, grid: before.grid, owner: id, ring: ring)
                    }
                }
                if let same = store.match(grid, ring: ring) {
                    store.alias(id, to: same.id)
                } else {
                    store.add(image, id: id, time: time + 0.15, reason: .click, grid: grid, ring: ring)
                }
            }
        }
        return id
    }

    /// Stops sampling, takes the last frame, and returns what was kept.
    func finish(duration: Double) -> AINotesFrameStore.Result {
        work.sync {
            timer?.cancel()
            timer = nil
            if let last = store.lastGrid, let buffer = snapshot(), let grid = AINotesLumaGrid(pixelBuffer: buffer), grid.distance(to: last) >= 0.004 {
                capture(id: makeID(), reason: .end, time: duration)
            }
            finished = true
            lock.lock()
            latest = nil
            lock.unlock()
            return store.finalize()
        }
    }

    /// Throws away everything written so far (the recording was cancelled).
    func discard() {
        work.sync {
            timer?.cancel()
            timer = nil
            finished = true
        }
    }

    // MARK: Work queue

    private func capture(id: Int, reason: Reason, time: Double, minimumChange: Double = 0) {
        guard !paused, !finished, let buffer = snapshot(), let grid = AINotesLumaGrid(pixelBuffer: buffer) else { return }
        if minimumChange > 0, let last = store.lastGrid, grid.distance(to: last) < minimumChange { return }
        // A window change right after another frame usually shows the same picture; reuse it.
        if reason == .page, let last = store.entries.last, abs(time - last.time) < 1.5, grid.distance(to: last.grid) < 0.004 {
            store.alias(id, to: last.id)
            return
        }
        guard let image = AINotesFrameEncoder.image(from: buffer, context: context) else { return }
        store.add(image, id: id, time: time, reason: reason, grid: grid)
    }

    /// Twice a second: has the screen moved far from the last kept frame, and has it settled?
    private func sample() {
        guard !paused, !finished else { return }
        if !tookStart {
            // The first video frame sets the clock; the opening frame waits for it.
            guard clock.isStarted else { return }
            capture(id: makeID(), reason: .start, time: 0)
            tookStart = !store.entries.isEmpty
            return
        }
        guard let time = clock.now, let buffer = snapshot(), let grid = AINotesLumaGrid(pixelBuffer: buffer) else { return }
        defer { previousGrid = grid }
        guard let kept = store.lastGrid else { return }
        // Small on purpose: an error message is a few lines of text, not a new page.
        guard grid.distance(to: kept) >= 0.003 else {
            changedSince = nil
            return
        }
        let since = changedSince ?? time
        changedSince = since
        // Wait for the change to finish (a page still loading, an animation), but not forever.
        let settled = previousGrid.map { grid.distance(to: $0) < 0.0015 } ?? false
        guard time - lastScreenFrame >= screenCooldown, settled || time - since >= 3 else { return }
        capture(id: makeID(), reason: .screen, time: time)
        lastScreenFrame = time
        screenCooldown = min(screenCooldown * 1.6, 20)
        changedSince = nil
    }
}
