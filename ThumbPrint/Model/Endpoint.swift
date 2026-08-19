import Foundation

/// One end of a copy: either a mounted drive, or a disk image file on disk.
///
/// This exists so a backup can be made without two sticks plugged in at once —
/// save to an image today, restore it to a different drive later.
///
/// The important thing about an image endpoint is that it is *temporary*. Once
/// `DiskImageStore.attach` mounts it, it becomes an ordinary `Drive` and every
/// engine downstream — `FileSyncEngine`, `Verifier`, `LibraryCheck`,
/// `SourceHealthCheck`, `PreflightReport` — treats it exactly like a USB stick,
/// because a mounted image *is* a mounted volume. That resolution happens once,
/// at the top of `CloneJob.analyze()`, and nothing after it knows the
/// difference. Adding image support therefore required no change to any copy
/// engine at all.
enum Endpoint: Hashable, Identifiable {
    case drive(Drive)
    case image(URL)

    /// Matches `Drive.id` (the volume path) for drives, so the "same thing
    /// picked on both sides" check in `CloneJob.canAnalyze` keeps working
    /// unchanged across both kinds.
    var id: String {
        switch self {
        case .drive(let drive): return drive.id
        case .image(let url): return url.path
        }
    }

    var displayName: String {
        switch self {
        case .drive(let drive): return drive.name
        case .image(let url): return url.lastPathComponent
        }
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    var driveValue: Drive? {
        if case .drive(let drive) = self { return drive }
        return nil
    }

    var imageURL: URL? {
        if case .image(let url) = self { return url }
        return nil
    }
}

extension Endpoint {
    /// The filename extension ThumbPrint writes and expects.
    ///
    /// Sparse rather than a fixed-size `.dmg`: the file grows only as far as the
    /// bytes actually stored, so a 128 GB stick holding an 81 GB library costs
    /// 81 GB on disk, not 128 GB.
    static let imageFileExtension = "sparseimage"
}
