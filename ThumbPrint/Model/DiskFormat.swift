import Foundation

/// A filesystem ThumbPrint is willing to put on a backup drive.
///
/// Deliberately only two, and deliberately the same two `DiskImageStore`
/// offers inside an image: this app exists to make DJ drives, and a DJ player
/// reads FAT32 or exFAT. Offering APFS or HFS+ here would produce a drive that
/// copies perfectly and then does nothing in a CDJ.
enum DiskFormat: String, CaseIterable, Identifiable {
    case exFAT
    case fat32

    var id: String { rawValue }

    /// `diskutil`'s spelling — and `hdiutil`'s, which is not a coincidence.
    /// These are the exact strings `DiskImageStore.filesystemArgument` returns,
    /// so a freshly formatted drive and an image made of one can't drift apart.
    var diskutilName: String {
        switch self {
        case .exFAT: return "ExFAT"
        case .fat32: return "MS-DOS FAT32"
        }
    }

    var title: String {
        switch self {
        case .exFAT: return "exFAT"
        case .fat32: return "FAT32"
        }
    }

    var subtitle: String {
        switch self {
        case .exFAT:
            return "Handles files over 4 GB. Needs a CDJ-3000, XDJ-XZ or XDJ-RX3 to read a rekordbox library."
        case .fat32:
            return "Read by every player ever made. No single file may exceed 4 GB."
        }
    }

    /// Volume label length the filesystem allows, which is what
    /// `DiskImageStore.sanitizedVolumeName` truncates to.
    var volumeNameLimit: Int { self == .exFAT ? 15 : 11 }

    /// FAT32 addresses at most 2^32 sectors of 512 bytes. `newfs_msdos` refuses
    /// anything larger, so the erase would fail after the partition map had
    /// already been rewritten — the worst possible moment. Caught before it
    /// starts instead.
    static let fat32MaximumCapacity: Int64 = 2 * 1024 * 1024 * 1024 * 1024

    /// **MBR, not GPT.** Pioneer players are documented against MBR-partitioned
    /// FAT32/exFAT sticks, and a GPT drive is the single most common reason a
    /// stick that mounts perfectly on a Mac shows nothing on a CDJ. macOS reads
    /// MBR without complaint, so there is no cost to the conservative choice.
    static let partitionScheme = "MBR"

    /// The format a drive already carries, when it's one of these two.
    ///
    /// Used to preselect: the standing default in this project is to match the
    /// source rather than to have an opinion.
    static func matching(_ formatDescription: String) -> DiskFormat? {
        let f = formatDescription.lowercased()
        // exFAT first: "exfat" also contains "fat".
        if f.contains("exfat") { return .exFAT }
        if f.contains("fat") { return .fat32 }
        return nil
    }
}
