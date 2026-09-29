import Foundation

/// A mounted volume that ThumbPrint is willing to read from or write to.
///
/// Only removable/ejectable external volumes are ever represented here — the
/// safety filter lives in `DriveScanner.eligibleDrive(for:)`, so by the time a
/// `Drive` exists it has already been cleared as a legal source or target.
struct Drive: Identifiable, Hashable {
    let volumeURL: URL
    let name: String

    /// BSD name of the *whole disk* (e.g. `disk4`), not the partition
    /// (`disk4s1`). Exact Clone must copy the partition map too, so cloning the
    /// partition alone would produce an unreadable target. `nil` when
    /// DiskArbitration can't resolve the volume, which disables Exact Clone.
    let wholeDiskBSDName: String?

    let totalCapacity: Int64
    let availableCapacity: Int64
    let volumeUUID: String?
    let formatDescription: String
    let isReadOnly: Bool

    var id: String { volumeURL.path }

    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    /// Character device — unbuffered, and roughly an order of magnitude faster
    /// than the block device for the sequential bulk transfer `dd` performs.
    var rawDevicePath: String? { wholeDiskBSDName.map { "/dev/r\($0)" } }

    var blockDevicePath: String? { wholeDiskBSDName.map { "/dev/\($0)" } }

    var supportsExactClone: Bool { wholeDiskBSDName != nil }

    /// exFAT is what essentially every DJ drive uses; FAT32 also appears on
    /// older/smaller sticks. Both are fine for Fast Sync.
    var isFATFamily: Bool {
        let f = formatDescription.lowercased()
        return f.contains("exfat") || f.contains("fat")
    }
}

extension Drive {
    /// Whether `current` — what is mounted at this drive's path *right now* — is
    /// still the same volume on the same physical disk.
    ///
    /// BSD names are handed out by macOS on attach and reused as soon as they're
    /// free, so `disk4` at preflight and `disk4` a minute later can be two
    /// different sticks. Anything that is about to act on a whole disk — an
    /// erase, a raw clone — re-reads the drive and asks this first. The volume
    /// UUID is what tells two sticks with the same name and number apart.
    func isSameDisk(as current: Drive?) -> Bool {
        guard let current, let bsdName = wholeDiskBSDName else { return false }
        return current.wholeDiskBSDName == bsdName && current.volumeUUID == volumeUUID
    }

    /// The same drive with its capacity re-read from the volume.
    ///
    /// A `Drive` is a snapshot taken when the volume was scanned, and a DJ drive
    /// routinely changes after that — plugged in, exported to from rekordbox,
    /// *then* backed up. Analysis runs on these figures, not the snapshot, so the
    /// free-space and cross-linked-cluster checks describe the drive as it is.
    /// Falls back to the snapshot if the volume can't be read; the copy's own
    /// mount checks will say so more usefully than this could.
    func refreshingCapacity() -> Drive {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? volumeURL.resourceValues(forKeys: keys) else { return self }
        return Drive(
            volumeURL: volumeURL,
            name: name,
            wholeDiskBSDName: wholeDiskBSDName,
            totalCapacity: values.volumeTotalCapacity.map(Int64.init) ?? totalCapacity,
            availableCapacity: values.volumeAvailableCapacity.map(Int64.init) ?? availableCapacity,
            volumeUUID: volumeUUID,
            formatDescription: formatDescription,
            isReadOnly: isReadOnly
        )
    }
}

extension Drive {
    static func == (lhs: Drive, rhs: Drive) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
