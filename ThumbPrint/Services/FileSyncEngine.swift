import Foundation

/// Mirrors the source volume onto the target at the file level.
///
/// Runs off the main actor — every call here performs blocking I/O.
final class FileSyncEngine {
    /// Large enough that per-chunk overhead is irrelevant next to USB transfer
    /// time, small enough to keep progress smooth and cancellation responsive.
    static let chunkSize = 4 * 1024 * 1024

    /// Temp files are written beside their destination and renamed on
    /// completion, so an interrupted copy can never leave a truncated file that
    /// a later run would accept as valid on size alone.
    ///
    /// Leftovers from a crash need no special cleanup: they aren't on the
    /// source, so the next run's mirror pass deletes them as orphans.
    static let tempPrefix = ".thumbprint-tmp-"

    struct Result {
        var filesCopied = 0
        var bytesCopied: Int64 = 0
        var itemsDeleted = 0
        var foldersCreated = 0
        var skipped: [String] = []
        var unreadableOnSource: [String] = []
    }

    private let onProgress: (CloneProgress) -> Void
    private var progress = CloneProgress()
    private var meter = ThroughputMeter()
    private var lastPublished = Date.distantPast

    /// Progress is emitted per chunk and per indexed file, which on a large
    /// library means tens of thousands of updates in a few seconds. Each one
    /// hops to the main actor, so publishing them all would swamp the UI it's
    /// trying to keep current. ~12/sec is well past what anyone can read.
    private static let publishInterval: TimeInterval = 0.08

    init(onProgress: @escaping (CloneProgress) -> Void) {
        self.onProgress = onProgress
    }

    // MARK: - Planning

    func makePlan(source: Drive, target: Drive) throws -> (plan: SyncPlan, sourceIndex: FileIndex, targetIndex: FileIndex) {
        publish { $0.stage = .indexingSource; $0.currentItem = source.name }
        let sourceIndex = try FileIndex.build(
            at: source.volumeURL,
            isCancelled: { Task.isCancelled },
            onCount: { count in
                self.publish { $0.itemsCompleted = count }
            }
        )

        publish { $0.stage = .indexingTarget; $0.currentItem = target.name; $0.itemsCompleted = 0 }
        let targetIndex = try FileIndex.build(
            at: target.volumeURL,
            isCancelled: { Task.isCancelled },
            onCount: { count in
                self.publish { $0.itemsCompleted = count }
            }
        )

        let plan = FileIndex.plan(source: sourceIndex, target: targetIndex)
        return (plan, sourceIndex, targetIndex)
    }

    // MARK: - Execution

    func execute(plan: SyncPlan, source: Drive, target: Drive, sourceIndex: FileIndex) throws -> Result {
        var result = Result()
        result.unreadableOnSource = sourceIndex.unreadablePaths

        try deleteOrphans(plan.itemsToDelete, on: target, source: source, into: &result)
        try createDirectories(plan.directoriesToCreate, on: target, source: source, into: &result)
        try copyFiles(plan.filesToCopy, from: source, to: target, into: &result)
        flush()

        return result
    }

    // MARK: - Phases

    /// Deletions run before copies: the target may be close to full, and
    /// freeing orphaned files first avoids a spurious out-of-space failure.
    private func deleteOrphans(
        _ items: [FileIndex.Entry],
        on target: Drive,
        source: Drive,
        into result: inout Result
    ) throws {
        guard !items.isEmpty else { return }

        publish {
            $0.stage = .deleting
            $0.itemsTotal = items.count
            $0.itemsCompleted = 0
            $0.bytesTotal = 0
            $0.bytesCompleted = 0
        }

        let fm = FileManager.default
        for (offset, entry) in items.enumerated() {
            try Task.checkCancellation()
            try ensureMounted(source: source, target: target)

            let url = target.volumeURL.appendingPathComponent(entry.relativePath)
            // Sorted deepest-first, so a directory is already empty here.
            // Missing items are fine — a parent may have taken a child with it.
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                    result.itemsDeleted += 1
                } catch {
                    result.skipped.append("Couldn't remove \(entry.relativePath)")
                }
            }

            publish { $0.itemsCompleted = offset + 1; $0.currentItem = entry.relativePath }
        }
    }

    private func createDirectories(
        _ items: [FileIndex.Entry],
        on target: Drive,
        source: Drive,
        into result: inout Result
    ) throws {
        guard !items.isEmpty else { return }

        publish {
            $0.stage = .creatingFolders
            $0.itemsTotal = items.count
            $0.itemsCompleted = 0
        }

        let fm = FileManager.default
        for (offset, entry) in items.enumerated() {
            try Task.checkCancellation()
            try ensureMounted(source: source, target: target)

            let url = target.volumeURL.appendingPathComponent(entry.relativePath)
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                result.foldersCreated += 1
            }

            publish { $0.itemsCompleted = offset + 1; $0.currentItem = entry.relativePath }
        }
    }

    private func copyFiles(
        _ files: [FileIndex.Entry],
        from source: Drive,
        to target: Drive,
        into result: inout Result
    ) throws {
        guard !files.isEmpty else { return }

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        publish {
            $0.stage = .copying
            $0.itemsTotal = files.count
            $0.itemsCompleted = 0
            $0.bytesTotal = totalBytes
            $0.bytesCompleted = 0
        }

        for (offset, entry) in files.enumerated() {
            // A pool per file as well as per chunk: FileManager, URL, and the
            // FileHandles all return autoreleased objects, and this loop runs
            // once for every file in the library.
            try autoreleasepool {
                try Task.checkCancellation()
                try ensureMounted(source: source, target: target)

                publish { $0.currentItem = entry.relativePath }

                let from = source.volumeURL.appendingPathComponent(entry.relativePath)
                let to = target.volumeURL.appendingPathComponent(entry.relativePath)

                do {
                    if entry.isSymbolicLink {
                        try copySymlink(from: from, to: to)
                    } else {
                        try copyFile(from: from, to: to, modificationDate: entry.modificationDate)
                        result.bytesCopied += entry.size
                    }
                    result.filesCopied += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CloneError {
                    throw error
                } catch {
                    // One unreadable track shouldn't abort a two-hour backup, but it
                    // must be reported — a silently missing file is exactly the
                    // failure this app exists to prevent.
                    result.skipped.append("\(entry.relativePath) — \(error.localizedDescription)")
                }

                publish { $0.itemsCompleted = offset + 1 }
            }
        }
    }

    // MARK: - Copying

    private func copyFile(from: URL, to: URL, modificationDate: Date) throws {
        let fm = FileManager.default
        let parent = to.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let temp = parent.appendingPathComponent(Self.tempPrefix + UUID().uuidString)

        do {
            guard fm.createFile(atPath: temp.path, contents: nil) else {
                throw CloneError.cannotReadVolume(to.lastPathComponent)
            }

            // Nested scope so both handles are closed before the rename.
            do {
                let input = try FileHandle(forReadingFrom: from)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: temp)
                defer { try? output.close() }

                // Each read hands back a Data backed by an autoreleased NSData.
                // This loop never suspends, so the enclosing pool doesn't drain
                // until the entire run ends — without a pool of its own, every
                // 4 MB chunk ever read stays live and the app's memory grows
                // 1:1 with bytes copied. An 18 GB library then costs 18 GB of
                // RAM, exhausts swap, and freezes the machine mid-backup.
                while true {
                    try Task.checkCancellation()

                    let reachedEnd = try autoreleasepool { () -> Bool in
                        guard let chunk = try input.read(upToCount: Self.chunkSize),
                              !chunk.isEmpty else {
                            return true
                        }
                        try output.write(contentsOf: chunk)

                        let rate = meter.record(bytes: Int64(chunk.count))
                        publish {
                            $0.bytesCompleted += Int64(chunk.count)
                            $0.bytesPerSecond = rate
                        }
                        return false
                    }

                    if reachedEnd { break }
                }
                try output.synchronize()
            }

            if fm.fileExists(atPath: to.path) {
                try fm.removeItem(at: to)
            }
            try fm.moveItem(at: temp, to: to)

            // Stamp the source's mtime so the next run's diff sees a match.
            // Without this every file looks changed and Fast Sync stops being fast.
            try? fm.setAttributes([.modificationDate: modificationDate], ofItemAtPath: to.path)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private func copySymlink(from: URL, to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) {
            try fm.removeItem(at: to)
        }
        let destination = try fm.destinationOfSymbolicLink(atPath: from.path)
        // exFAT has no symlinks; this throws there and the caller records a skip.
        try fm.createSymbolicLink(atPath: to.path, withDestinationPath: destination)
    }

    // MARK: - Helpers

    private func ensureMounted(source: Drive, target: Drive) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.volumeURL.path) else {
            throw CloneError.sourceDisappeared(source.name)
        }
        guard fm.fileExists(atPath: target.volumeURL.path) else {
            throw CloneError.targetDisappeared(target.name)
        }
    }

    /// Coalesces progress updates, but always lets a stage change through so
    /// the headline label never lags behind what's actually happening.
    private func publish(_ mutate: (inout CloneProgress) -> Void) {
        let previousStage = progress.stage
        mutate(&progress)

        let now = Date()
        let stageChanged = progress.stage != previousStage
        guard stageChanged || now.timeIntervalSince(lastPublished) >= Self.publishInterval else {
            return
        }

        lastPublished = now
        onProgress(progress)
    }

    /// Forces the current state out, so a throttled final update can't leave
    /// the bar stuck just short of complete.
    private func flush() {
        lastPublished = Date()
        onProgress(progress)
    }
}
