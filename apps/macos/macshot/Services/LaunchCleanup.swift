import Foundation

// MARK: - DirectorySweeper
//
// One place that knows how to walk a directory, read modification times,
// and delete files older than a TTL that pass a caller-supplied filter.
// Every cleanup we do at launch boils down to this operation — sharing
// the implementation keeps each cleaner down to declarative config.

enum DirectorySweeper {

    /// Result of a sweep, handy for logging.
    struct Result {
        var removed: Int = 0
        var bytesFreed: UInt64 = 0
    }

    /// Walk `directory` (no recursion), and delete regular files that
    /// satisfy `shouldDelete`. When `olderThan` is non-nil, files
    /// modified more recently than `now - olderThan` are skipped so
    /// in-flight writes can't get clobbered. Returns counts for logging.
    ///
    /// - Parameters:
    ///   - directory: Directory to scan. Missing directory → empty result.
    ///   - olderThan: Age gate. Pass nil to skip the age check entirely
    ///     (e.g. when using an independent signal like "orphaned from
    ///     an index file").
    ///   - shouldDelete: Filter run on the filename (last path component
    ///     only). Return true to include the file, false to leave it.
    @discardableResult
    static func sweep(directory: URL,
                      olderThan ttl: TimeInterval?,
                      now: Date = Date(),
                      shouldDelete: (String) -> Bool) -> Result {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return Result() }

        let cutoff: Date? = ttl.map { now.addingTimeInterval(-$0) }
        var result = Result()

        for url in contents {
            guard shouldDelete(url.lastPathComponent) else { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
            ]) else { continue }
            guard values.isRegularFile == true else { continue }
            if let cutoff = cutoff {
                guard let modified = values.contentModificationDate,
                      modified < cutoff else { continue }
            }

            let size = UInt64(values.fileSize ?? 0)
            if (try? fm.removeItem(at: url)) != nil {
                result.removed += 1
                result.bytesFreed += size
            }
        }
        return result
    }

    /// Same idea for subdirectories, which `sweep` deliberately skips. Used for
    /// the share scratch folder, where each share gets its own directory so two
    /// files with the same name can't collide.
    @discardableResult
    static func sweepDirectories(in directory: URL,
                                 olderThan ttl: TimeInterval,
                                 shouldDelete: (String) -> Bool = { _ in true }) -> Result {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return Result() }

        let cutoff = Date().addingTimeInterval(-ttl)
        var result = Result()

        for url in contents {
            guard shouldDelete(url.lastPathComponent) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }

            let size = directorySize(at: url)
            if (try? fm.removeItem(at: url)) != nil {
                result.removed += 1
                result.bytesFreed += size
            }
        }
        return result
    }

    private static func directorySize(at url: URL) -> UInt64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsSubdirectoryDescendants])) ?? []
        return contents.reduce(0) { total, file in
            total + UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}

// MARK: - LaunchCleaner

/// One discrete cleanup task that runs at app launch. Each implementation
/// encodes a single rule ("sweep X older than Y") and nothing else —
/// add a new cleaner by conforming, then registering in `LaunchCleanup.all`.
protocol LaunchCleaner {
    /// Short name used for debug logging.
    var name: String { get }
    /// Do the work. Expected to run quickly (I/O only) and return. The
    /// caller dispatches to a background queue, so implementations are
    /// free to block.
    func sweep() -> DirectorySweeper.Result
}

// MARK: - Registry

enum LaunchCleanup {
    static func ownsTemporaryFilename(_ name: String) -> Bool {
        guard name != "pressshot-clipboard.png",
              !name.hasPrefix("pressshot-clipboard-recording.") else { return false }
        return name.hasPrefix("pressshot_upload_") || name.hasPrefix("pressshot-clipboard-")
    }


    /// All cleaners that should run on launch. Order doesn't matter.
    /// Adding a new leak handler is a one-line addition here plus a new
    /// `LaunchCleaner`-conforming type.
    static let all: [LaunchCleaner] = [
        TmpFileCleaner(),
        EditorSourceCleaner(),
        ScratchDirectoryCleaner(),
        LegacyClipboardBackingDirectoryCleaner(),
        LegacyClipboardTmpDirectoryCleaner(),
    ]

    /// Run every cleaner off the main thread. Safe to call from
    /// `applicationDidFinishLaunching`.
    static func runAll() {
        DispatchQueue.global(qos: .utility).async {
            for cleaner in all {
                let result = cleaner.sweep()
                #if DEBUG
                if result.removed > 0 {
                    print("[\(cleaner.name)] removed \(result.removed) files, freed \(result.bytesFreed) bytes")
                }
                #endif
            }
        }
    }
}

// MARK: - Concrete cleaners

private struct EditorSourceCleaner: LaunchCleaner {
    let name = "EditorSourceCleaner"
    func sweep() -> DirectorySweeper.Result {
        // APFS clones can share blocks with the original, so a file's logical
        // size is not a meaningful estimate of reclaimed storage here.
        DirectorySweeper.Result(removed: VideoSourceSnapshot.removeAbandonedTemporaryCopies())
    }
}

/// Only remove explicitly PressShot-named temporaries. Unsigned development
/// builds share the user temp directory with MacShot and other applications;
/// generic UUID/Recording names are not sufficient evidence of ownership.
private struct TmpFileCleaner: LaunchCleaner {
    let name = "TmpFileCleaner"
    func sweep() -> DirectorySweeper.Result {
        DirectorySweeper.sweep(directory: FileManager.default.temporaryDirectory,
            olderThan: 24 * 60 * 60, shouldDelete: LaunchCleanup.ownsTemporaryFilename)
    }
}

/// Sweeps everything in `tmp/macshot-share/` older than 5 minutes.
/// That subfolder is exclusively used for drag-to-Finder and
/// share-sheet scratch files whose names follow the user-configured
/// filename template (so they can't be pattern-matched reliably). The
/// 5-minute TTL is far longer than any share/drag in practice.
private struct ScratchDirectoryCleaner: LaunchCleaner {
    let name = "ScratchDirectoryCleaner"
    private let ttl: TimeInterval = 5 * 60

    func sweep() -> DirectorySweeper.Result {
        // Each share writes into its own subfolder (see TmpScratchDirectory),
        // so both loose files from older builds and those folders need sweeping.
        var result = DirectorySweeper.sweep(
            directory: TmpScratchDirectory.url,
            olderThan: ttl,
            shouldDelete: { _ in true }
        )
        let directories = DirectorySweeper.sweepDirectories(
            in: TmpScratchDirectory.url,
            olderThan: ttl
        )
        result.removed += directories.removed
        result.bytesFreed += directories.bytesFreed
        return result
    }
}

/// Sweeps the legacy clipboard backing folder from builds that put file URLs on the pasteboard.
/// The 7-day TTL matches the old retention so clipboard history entries don't break on update.
private struct LegacyClipboardBackingDirectoryCleaner: LaunchCleaner {
    let name = "LegacyClipboardBackingDirectoryCleaner"

    func sweep() -> DirectorySweeper.Result {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return DirectorySweeper.Result()
        }
        let dir = appSupport
            .appendingPathComponent("com.derekhanson.pressshot", isDirectory: true)
            .appendingPathComponent("clipboard", isDirectory: true)
        let result = DirectorySweeper.sweep(
            directory: dir,
            olderThan: 7 * 24 * 60 * 60,
            shouldDelete: { _ in true }
        )
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: dir.path), remaining.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
        return result
    }
}

/// Sweeps the legacy `/tmp/macshot-clipboard/` folder used by older builds.
/// Keep a 24h TTL so an update/restart does not immediately break a pasteboard
/// item copied right before the app was relaunched.
private struct LegacyClipboardTmpDirectoryCleaner: LaunchCleaner {
    let name = "LegacyClipboardTmpDirectoryCleaner"
    private let ttl: TimeInterval = 24 * 60 * 60

    func sweep() -> DirectorySweeper.Result {
        return DirectorySweeper.sweep(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("pressshot-clipboard"),
            olderThan: ttl,
            shouldDelete: { _ in true }
        )
    }
}
