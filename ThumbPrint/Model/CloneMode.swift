import Foundation

enum CloneMode: String, CaseIterable, Identifiable {
    /// Mirror the source's *files* onto the target, copying only what changed.
    case fastSync
    /// Bit-for-bit raw block copy of the whole disk.
    case exactClone
    /// Two-way read-only diff. Writes nothing to either drive.
    case compareOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastSync: return "Fast Sync"
        case .exactClone: return "Exact Clone"
        case .compareOnly: return "Compare"
        }
    }

    var subtitle: String {
        switch self {
        case .fastSync:
            return "Copies only what changed. Backup ends up identical to the source."
        case .exactClone:
            return "Bit-for-bit copy of the entire disk. Needs an admin password."
        case .compareOnly:
            return "Shows what's different between two drives. Writes nothing to either one."
        }
    }

    var requiresAdmin: Bool { self == .exactClone }

    /// True for modes that only ever read. Used to drop the write-side chrome —
    /// the read-only target check, the "will be changed" labelling, the Start
    /// button — from a mode that has no write step to gate.
    var isInspection: Bool { self == .compareOnly }

    /// Whether either side of this mode may be a disk image file rather than a
    /// drive.
    ///
    /// False for Exact Clone, and not as a formality: that mode copies raw blocks
    /// between `/dev/rdisk` nodes, and an attached image really does present one.
    /// Without this refusal the mode would happily `dd` onto an image — producing
    /// something that is neither a valid image file nor a working drive. Fast Sync
    /// and Compare are file-level, so to them an image is just another volume.
    var allowsImageEndpoints: Bool { self != .exactClone }
}
