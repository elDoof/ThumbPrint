import Foundation

/// A snapshot of one volume's file tree, keyed by relative path.
///
/// This is the pure, testable core of Fast Sync: build one index per drive,
/// diff them, and the result is the complete list of work to do.
struct FileIndex {
    struct Entry: Hashable {
        let relativePath: String
        let size: Int64
        let modificationDate: Date
        let isDirectory: Bool
        let isSymbolicLink: Bool

        /// Depth is used to order work: directories are created shallowest
        /// first, deletions performed deepest first.
        var depth: Int { relativePath.components(separatedBy: "/").count }
    }

    /// exFAT records modification times with 2-second granularity, so a
    /// byte-perfect copy routinely reads back 0–2s away from its source. Any
    /// stricter comparison would re-copy the entire library on every run and
    /// defeat the point of an incremental sync.
    static let modificationTolerance: TimeInterval = 2.0

    /// Volume-level caches macOS regenerates on demand. They are often
    /// unreadable without extra privileges, can run to gigabytes, and mean
    /// nothing to a DJ player — copying them adds time and failure modes for
    /// no benefit. Matched only at the volume root.
    static let excludedRootNames: Set<String> = [
        ".Spotlight-V100",
        ".fseventsd",
        ".TemporaryItems",
        ".Trashes",
        ".DocumentRevisions-V100",
        ".apdisk",
    ]

    private(set) var entries: [String: Entry] = [:]

    /// Paths that could not be read while indexing. Surfaced in the summary
    /// rather than silently dropped — an unreadable source file is exactly the
    /// kind of thing that must not vanish quietly from a backup.
    private(set) var unreadablePaths: [String] = []

    var fileEntries: [Entry] { entries.values.filter { !$0.isDirectory } }
    var directoryEntries: [Entry] { entries.values.filter { $0.isDirectory } }
    var fileCount: Int { fileEntries.count }
    var totalBytes: Int64 { fileEntries.reduce(0) { $0 + $1.size } }
}

// MARK: - Building

extension FileIndex {
    static func build(
        at root: URL,
        isCancelled: () -> Bool = { false },
        onCount: (Int) -> Void = { _ in }
    ) throws -> FileIndex {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]

        var index = FileIndex()
        let rootPath = root.standardizedFileURL.path

        // NOTE: options is deliberately empty. Passing `.skipsHiddenFiles`
        // would drop Rekordbox's /PIONEER/, Serato's /_Serato_/, and every
        // AppleDouble `._` sidecar — producing a backup that looks complete in
        // Finder and fails to load in a CDJ.
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, _ in
                // Record the full relative path, matching every other path in
                // the index. A bare filename is unactionable in a library with
                // hundreds of folders — "track.mp3 couldn't be read" gives the
                // user no way to find the file this backup is missing.
                let relative = relativePath(of: url, under: rootPath)
                index.unreadablePaths.append(relative.isEmpty ? url.lastPathComponent : relative)
                return true
            }
        ) else {
            throw CloneError.cannotReadVolume(root.lastPathComponent)
        }

        let keySet = Set(keys)

        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }

            // The enumerator and `resourceValues` both hand back autoreleased
            // objects, and this loop runs once per item on the volume. The walk
            // never suspends, so without a pool per iteration they accumulate
            // for its entire duration — on a large library that's hundreds of
            // megabytes held for no reason, three times per run.
            autoreleasepool {
                if enumerator.level == 1, excludedRootNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    return
                }

                let relative = relativePath(of: url, under: rootPath)
                guard !relative.isEmpty else { return }

                guard let values = try? url.resourceValues(forKeys: keySet) else {
                    index.unreadablePaths.append(relative)
                    return
                }

                let isDirectory = values.isDirectory ?? false
                index.entries[relative] = Entry(
                    relativePath: relative,
                    size: isDirectory ? 0 : Int64(values.fileSize ?? 0),
                    modificationDate: values.contentModificationDate ?? .distantPast,
                    isDirectory: isDirectory,
                    isSymbolicLink: values.isSymbolicLink ?? false
                )
                onCount(index.entries.count)
            }
        }

        return index
    }

    /// Path relative to the volume root, normalized to NFC.
    ///
    /// Normalization matters: APFS hands back decomposed (NFD) filenames while
    /// exFAT stores whatever was written to it. Without a common form, a track
    /// like "Beyoncé.mp3" indexes under two different keys on the two drives
    /// and gets re-copied forever.
    private static func relativePath(of url: URL, under rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return "" }
        var relative = String(path.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative.precomposedStringWithCanonicalMapping
    }
}

// MARK: - Diffing

/// The complete set of changes that turns the target into a copy of the source.
struct SyncPlan {
    var directoriesToCreate: [FileIndex.Entry] = []
    var filesToCopy: [FileIndex.Entry] = []
    var itemsToDelete: [FileIndex.Entry] = []

    var bytesToCopy: Int64 { filesToCopy.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool {
        directoriesToCreate.isEmpty && filesToCopy.isEmpty && itemsToDelete.isEmpty
    }
}

/// A two-way difference between drives, for inspection rather than copying.
///
/// `SyncPlan` deliberately folds "missing from the target" and "present but
/// different" into one `filesToCopy` list, because the work to fix either is
/// identical. A comparison has to keep them apart: when nobody is about to write
/// anything, "this drive doesn't have it" and "both have it and they disagree"
/// are different findings for the person reading the screen.
///
/// Directories are ignored. A folder that exists on one side only is already
/// implied by the files listed inside it, and listing both is noise.
struct FileComparison {
    /// `left`'s copy of each entry throughout — for `differing`, that means the
    /// size and date shown are the left drive's.
    var onlyOnLeft: [FileIndex.Entry] = []
    var onlyOnRight: [FileIndex.Entry] = []
    var differing: [FileIndex.Entry] = []
    var identicalCount = 0

    var isIdentical: Bool {
        onlyOnLeft.isEmpty && onlyOnRight.isEmpty && differing.isEmpty
    }

    var differenceCount: Int {
        onlyOnLeft.count + onlyOnRight.count + differing.count
    }

    var bytesOnlyOnLeft: Int64 { onlyOnLeft.reduce(0) { $0 + $1.size } }
    var bytesOnlyOnRight: Int64 { onlyOnRight.reduce(0) { $0 + $1.size } }
}

extension FileIndex {
    /// Compares two indexes without reference to which one is "correct".
    ///
    /// Uses the same `modificationTolerance` as `plan` — on a FAT-family volume
    /// a byte-perfect copy reads back up to 2s off its source, so a stricter
    /// comparison would report an entire library as differing.
    static func compare(left: FileIndex, right: FileIndex) -> FileComparison {
        var result = FileComparison()

        for entry in left.fileEntries {
            // A path that is a file on the left and a directory on the right is
            // reported as left-only rather than differing: the right drive does
            // not have this file, it has something else wearing its name.
            guard let other = right.entries[entry.relativePath], !other.isDirectory else {
                result.onlyOnLeft.append(entry)
                continue
            }

            let sizeChanged = other.size != entry.size
            let timeChanged = abs(
                other.modificationDate.timeIntervalSince(entry.modificationDate)
            ) > modificationTolerance

            if sizeChanged || timeChanged {
                result.differing.append(entry)
            } else {
                result.identicalCount += 1
            }
        }

        for entry in right.fileEntries where left.entries[entry.relativePath] == nil {
            result.onlyOnRight.append(entry)
        }

        result.onlyOnLeft.sort { $0.relativePath < $1.relativePath }
        result.onlyOnRight.sort { $0.relativePath < $1.relativePath }
        result.differing.sort { $0.relativePath < $1.relativePath }

        return result
    }
}

extension FileIndex {
    static func plan(source: FileIndex, target: FileIndex) -> SyncPlan {
        var plan = SyncPlan()

        for (path, entry) in source.entries {
            let existing = target.entries[path]

            if entry.isDirectory {
                if existing == nil || existing?.isDirectory == false {
                    plan.directoriesToCreate.append(entry)
                }
                continue
            }

            guard let existing, !existing.isDirectory else {
                plan.filesToCopy.append(entry)
                continue
            }

            let sizeChanged = existing.size != entry.size
            let timeChanged = abs(
                existing.modificationDate.timeIntervalSince(entry.modificationDate)
            ) > modificationTolerance

            if sizeChanged || timeChanged {
                plan.filesToCopy.append(entry)
            }
        }

        // Mirror semantics: anything on the target the source no longer has.
        for (path, entry) in target.entries where source.entries[path] == nil {
            plan.itemsToDelete.append(entry)
        }

        // Shallowest first so parents exist before children.
        plan.directoriesToCreate.sort { $0.depth < $1.depth }
        // Deepest first so directories are empty by the time they're removed.
        plan.itemsToDelete.sort { $0.depth > $1.depth }
        // Stable, human-legible copy order.
        plan.filesToCopy.sort { $0.relativePath < $1.relativePath }

        return plan
    }
}
