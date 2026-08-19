import Foundation

/// What ThumbPrint remembers about one drive between launches.
///
/// Keyed by volume UUID, never by name or mount path: DJ drives are routinely
/// called `UNTITLED`, and `/Volumes/HOTFIRE 1` is what macOS hands you when two
/// drives share a name. A drive whose UUID can't be read is simply not tracked —
/// guessing identity from a name is how a registry starts lying about which
/// stick is which.
///
/// Everything here is convenience data. It is stored in the app's own Application
/// Support directory and **never on a drive** — a backup tool that writes its own
/// bookkeeping onto a DJ drive is adding files a player has to ignore, on the one
/// volume this app exists to leave alone.
struct DriveRecord: Codable, Equatable, Identifiable {
    let volumeUUID: String

    /// Last known name and shape. Kept current on every sighting so the registry
    /// can still describe a drive that isn't plugged in.
    var name: String
    var formatDescription: String
    var totalCapacity: Int64

    var firstSeen: Date
    var lastSeen: Date

    /// What was on the drive the last time ThumbPrint indexed it.
    var contents: ContentSnapshot?

    /// The last completed copy this drive took part in, in either role.
    var lastSync: SyncRecord?

    var id: String { volumeUUID }
}

/// Which side of a copy a drive was on.
enum DriveRole: String, Codable {
    case source
    case backup
}

/// A summary of a drive's contents, cheap enough to keep forever.
///
/// Deliberately not a file list. A per-track manifest is a genuinely useful
/// thing — it's what tells you what you lost when a drive dies — but it's also
/// megabytes per drive per snapshot, so it belongs in its own feature with its
/// own storage decisions rather than smuggled into the registry.
struct ContentSnapshot: Codable, Equatable {
    var fileCount: Int
    var totalBytes: Int64

    /// Raw values of the `LibraryReport.Kind`s found, e.g. `["rekordbox"]`.
    /// Stored as strings so adding a case can't fail to decode old files.
    var libraries: [String]

    var audioFileCount: Int

    /// Modification date of the newest library database found, if any. This is
    /// what makes "your backup's library is three weeks older than your gig
    /// drive's" answerable without both drives being plugged in.
    var newestDatabaseModified: Date?

    var hasLibrary: Bool { !libraries.isEmpty }
}

extension ContentSnapshot {
    init(index: FileIndex, library: LibraryReport) {
        self.fileCount = index.fileCount
        self.totalBytes = index.totalBytes
        self.libraries = library.libraries.map(\.kind.rawValue).sorted()
        self.audioFileCount = library.audioFileCount
        self.newestDatabaseModified = library.libraries.map(\.databaseModified).max()
    }
}

/// One completed copy, from the point of view of one of the two drives.
struct SyncRecord: Codable, Equatable {
    var finishedAt: Date
    var role: DriveRole
    var otherDriveName: String
    var filesCopied: Int
    var bytesCopied: Int64
    var duration: TimeInterval

    /// False when the run finished but verification found discrepancies, or was
    /// skipped. "Backed up 3 days ago" would be an overstatement for a run that
    /// didn't verify, so the distinction is kept rather than flattened.
    var verified: Bool

    /// Set when the other side was a `.sparseimage` file rather than a drive.
    ///
    /// Optional so a `drives.json` written before disk images existed still
    /// decodes — no schema bump. `DriveRole` deliberately gains no `.image` case
    /// for the mirror-image reason: a new case would make files written by this
    /// build undecodable by an older one, which is exactly the corruption path
    /// `DriveRegistryStore` goes out of its way to avoid. `otherDriveName` carries
    /// the file's display name, so the picker's history line needs no change.
    var imagePath: String?

    /// Averaged over the whole run, so it includes indexing and deletion — not a
    /// clean read-throughput figure. Recorded because a drive that used to sync
    /// at 45 MB/s and now manages 12 is worth noticing; interpreting it as a
    /// benchmark would be reading more into it than it holds.
    var averageBytesPerSecond: Double {
        guard duration > 0 else { return 0 }
        return Double(bytesCopied) / duration
    }
}
