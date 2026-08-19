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
    static func == (lhs: Drive, rhs: Drive) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
