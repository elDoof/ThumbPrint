import Foundation

/// Persistence for what ThumbPrint remembers about drives.
///
/// Deliberately a plain value type with no actor isolation and no observation:
/// every decision in here — schema versioning, what happens to a corrupt file,
/// what a sighting updates — is worth testing directly, and `DriveRegistry` adds
/// the `@Observable` layer the UI needs on top.
///
/// The file lives in the app's own Application Support directory. It must never
/// be written to a drive: this app's entire premise is that it doesn't add files
/// to a DJ volume.
struct DriveRegistryStore: Equatable {
    /// Bumped when the on-disk shape changes in a way old builds can't read.
    static let schemaVersion = 1

    private(set) var records: [String: DriveRecord] = [:]

    /// False when the file on disk was written by a newer schema than this build
    /// understands. Such a file is left completely alone — no records are loaded
    /// from it and `save` refuses, because overwriting it would destroy data a
    /// later version of the app is relying on.
    private(set) var canSave = true

    var driveCount: Int { records.count }

    func record(for drive: Drive) -> DriveRecord? {
        drive.volumeUUID.flatMap { records[$0] }
    }
}

// MARK: - Location

extension DriveRegistryStore {
    /// `~/Library/Application Support/ThumbPrint/drives.json`.
    static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        return base
            .appendingPathComponent("ThumbPrint", isDirectory: true)
            .appendingPathComponent("drives.json", isDirectory: false)
    }
}

// MARK: - Codable payload

extension DriveRegistryStore {
    /// Stored as an array rather than a dictionary keyed by UUID: the UUID is
    /// already inside each record, and an array keeps the file readable by a
    /// human trying to work out what the app thinks it knows.
    private struct Payload: Codable {
        var version: Int
        var drives: [DriveRecord]
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // This file is small, rarely written, and occasionally read by a person
        // debugging why the app thinks a drive is a week behind.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Loading

extension DriveRegistryStore {
    /// Never throws. The registry is convenience data — failing to read it must
    /// not stop someone backing up a drive.
    ///
    /// A file that can't be decoded is *moved aside*, not overwritten. It may be
    /// the only record of which drive was which, and silently deleting it to get
    /// a clean start is the kind of quiet data loss this project doesn't do.
    static func load(from url: URL) -> DriveRegistryStore {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return DriveRegistryStore()
        }

        guard let payload = try? makeDecoder().decode(Payload.self, from: data) else {
            setAside(url, reason: "unreadable")
            return DriveRegistryStore()
        }

        if payload.version > schemaVersion {
            var store = DriveRegistryStore()
            store.canSave = false
            return store
        }

        var store = DriveRegistryStore()
        // Last one wins on a duplicated UUID. A hand-edited file is the only way
        // to get one, and refusing to load at all would be a worse outcome than
        // picking a record.
        for record in payload.drives {
            store.records[record.volumeUUID] = record
        }
        return store
    }

    private static func setAside(_ url: URL, reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.appendingPathExtension("\(reason)-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}

// MARK: - Saving

extension DriveRegistryStore {
    func save(to url: URL) throws {
        guard canSave else { return }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let payload = Payload(
            version: Self.schemaVersion,
            // Sorted so the file doesn't reshuffle on every write, which would
            // make a diff between two versions of it useless.
            drives: records.values.sorted { $0.volumeUUID < $1.volumeUUID }
        )

        // `.atomic` writes a temp file and renames, so an interrupted write can't
        // leave a truncated JSON file that the next launch treats as corrupt.
        try Self.makeEncoder().encode(payload).write(to: url, options: .atomic)
    }
}

// MARK: - Recording

extension DriveRegistryStore {
    /// A drive was seen mounted. Refreshes the mutable facts about it.
    ///
    /// Drives with no readable volume UUID are ignored outright — see
    /// `DriveRecord` for why identity is never inferred from a name.
    mutating func noteSeen(_ drive: Drive, at now: Date = Date()) {
        guard let uuid = drive.volumeUUID else { return }

        if var existing = records[uuid] {
            existing.name = drive.name
            existing.formatDescription = drive.formatDescription
            existing.totalCapacity = drive.totalCapacity
            existing.lastSeen = now
            records[uuid] = existing
        } else {
            records[uuid] = DriveRecord(
                volumeUUID: uuid,
                name: drive.name,
                formatDescription: drive.formatDescription,
                totalCapacity: drive.totalCapacity,
                firstSeen: now,
                lastSeen: now
            )
        }
    }

    /// A drive was indexed, so what's on it is known.
    mutating func noteContents(
        _ drive: Drive,
        index: FileIndex,
        library: LibraryReport? = nil,
        at now: Date = Date()
    ) {
        noteSeen(drive, at: now)
        guard let uuid = drive.volumeUUID else { return }
        records[uuid]?.contents = ContentSnapshot(
            index: index,
            library: library ?? LibraryReport.evaluate(index: index)
        )
    }

    /// A copy completed. Both drives get a record of it, from their own side.
    ///
    /// Takes primitives rather than a `CloneSummary` so this stays independent of
    /// the engines and testable on its own.
    ///
    /// `sourceIndex` updates the source's content snapshot. The target's snapshot
    /// is set from the same index **only when the run verified**, because that is
    /// precisely what a verified mirror means: the target now holds what the
    /// source holds. An unverified run has no such guarantee, so the target's
    /// previous snapshot is left in place rather than replaced with a claim.
    mutating func noteSync(
        source: Drive,
        target: Drive,
        filesCopied: Int,
        bytesCopied: Int64,
        duration: TimeInterval,
        verified: Bool,
        sourceIndex: FileIndex? = nil,
        at now: Date = Date()
    ) {
        noteSeen(source, at: now)
        noteSeen(target, at: now)

        if let uuid = source.volumeUUID {
            records[uuid]?.lastSync = SyncRecord(
                finishedAt: now,
                role: .source,
                otherDriveName: target.name,
                filesCopied: filesCopied,
                bytesCopied: bytesCopied,
                duration: duration,
                verified: verified
            )
        }

        if let uuid = target.volumeUUID {
            records[uuid]?.lastSync = SyncRecord(
                finishedAt: now,
                role: .backup,
                otherDriveName: source.name,
                filesCopied: filesCopied,
                bytesCopied: bytesCopied,
                duration: duration,
                verified: verified
            )
        }

        guard let sourceIndex else { return }
        let library = LibraryReport.evaluate(index: sourceIndex)
        if let uuid = source.volumeUUID {
            records[uuid]?.contents = ContentSnapshot(index: sourceIndex, library: library)
        }
        if verified, let uuid = target.volumeUUID {
            records[uuid]?.contents = ContentSnapshot(index: sourceIndex, library: library)
        }
    }

    /// A copy between a drive and a disk image file.
    ///
    /// Only the drive gets a record. A mounted image does have a volume UUID, so
    /// recording it would silently work — and then the registry would hold a row
    /// nothing can ever display, whose sighting dates only move on the days the
    /// image happens to be opened. An image's identity is its path, and paths
    /// move; the path goes in `SyncRecord.imagePath` instead.
    ///
    /// `role` is the *drive's* role: `.source` when saving a drive into an image,
    /// `.backup` when restoring an image onto a drive.
    mutating func noteImageSync(
        drive: Drive,
        role: DriveRole,
        imageURL: URL,
        filesCopied: Int,
        bytesCopied: Int64,
        duration: TimeInterval,
        verified: Bool,
        sourceIndex: FileIndex? = nil,
        at now: Date = Date()
    ) {
        noteSeen(drive, at: now)
        guard let uuid = drive.volumeUUID else { return }

        records[uuid]?.lastSync = SyncRecord(
            finishedAt: now,
            role: role,
            otherDriveName: imageURL.deletingPathExtension().lastPathComponent,
            filesCopied: filesCopied,
            bytesCopied: bytesCopied,
            duration: duration,
            verified: verified,
            imagePath: imageURL.path
        )

        guard let sourceIndex else { return }
        let library = LibraryReport.evaluate(index: sourceIndex)

        // Same rule as `noteSync`, applied to whichever side the drive was on.
        // Saving: the index IS the drive's own, so it always describes it.
        // Restoring: the index is the image's, so it only describes the drive
        // once the run verified — which is exactly what a verified mirror
        // asserts.
        if role == .source || verified {
            records[uuid]?.contents = ContentSnapshot(index: sourceIndex, library: library)
        }
    }
}
