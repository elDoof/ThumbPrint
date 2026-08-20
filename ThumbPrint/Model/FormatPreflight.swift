import Foundation

/// The rules that decide whether a drive may be erased, and what the user must
/// be told before it happens.
///
/// Kept apart from `DriveFormatter` for the same reason `ImagePreflight` is kept
/// apart from `PreflightReport`: this is the safety-critical half, one of its
/// rules is a direct guard on [the one rule](docs/DEVELOPMENT.md), and it has to
/// be drivable by `Tests/run.sh` without a drive, a subprocess or a main actor.
/// Every function here is pure.
///
/// Erasing is the only destructive thing ThumbPrint does that isn't a copy, so
/// the approval it produces is a *token*: `DriveFormatter.erase` takes an
/// `EraseApproval` and nothing else, and an `EraseApproval` can only be minted
/// here, by `approve(_:)`, and only when there are no blockers. A future caller
/// cannot skip these checks by accident — there is no other way to spell the
/// argument.
struct FormatPreflight {

    /// One partition on the physical disk about to be repartitioned.
    ///
    /// The whole disk is erased, so every one of these goes. They're listed by
    /// name in the confirmation for exactly that reason.
    struct SiblingVolume: Equatable {
        var deviceIdentifier: String
        var volumeName: String?
        var content: String
        var size: Int64
        var isMounted: Bool

        init(
            deviceIdentifier: String,
            volumeName: String? = nil,
            content: String = "",
            size: Int64 = 0,
            isMounted: Bool = false
        ) {
            self.deviceIdentifier = deviceIdentifier
            self.volumeName = volumeName
            self.content = content
            self.size = size
            self.isMounted = isMounted
        }

        var displayName: String {
            if let volumeName, !volumeName.isEmpty { return volumeName }
            if !content.isEmpty { return "\(content) partition (\(deviceIdentifier))" }
            return deviceIdentifier
        }
    }

    struct Facts: Equatable {
        /// The drive the user picked to erase.
        var drive: Drive
        var format: DiskFormat
        /// What the user typed. Sanitized before it reaches the approval.
        var requestedName: String

        /// Size of the *physical disk*, not the volume — the FAT32 ceiling is a
        /// property of the disk being partitioned.
        var wholeDiskSize: Int64

        /// Every partition currently on that physical disk, this one included.
        var siblings: [SiblingVolume]

        /// The volume path of the drive currently selected as the copy's source,
        /// if any. Erasing it is the one thing that must never happen.
        var sourceVolumePath: String?

        /// And its physical disk, so a *different partition of the same stick*
        /// is refused too. Erasing the whole disk would take the source with it.
        var sourceWholeDiskBSDName: String?

        /// Any `.sparseimage` currently selected on either side of a copy. One
        /// living on this drive would be destroyed by the erase.
        var selectedImageURLs: [URL]

        init(
            drive: Drive,
            format: DiskFormat,
            requestedName: String,
            wholeDiskSize: Int64,
            siblings: [SiblingVolume] = [],
            sourceVolumePath: String? = nil,
            sourceWholeDiskBSDName: String? = nil,
            selectedImageURLs: [URL] = []
        ) {
            self.drive = drive
            self.format = format
            self.requestedName = requestedName
            self.wholeDiskSize = wholeDiskSize
            self.siblings = siblings
            self.sourceVolumePath = sourceVolumePath
            self.sourceWholeDiskBSDName = sourceWholeDiskBSDName
            self.selectedImageURLs = selectedImageURLs
        }
    }

    // MARK: - Rules

    static func evaluate(_ facts: Facts) -> (blockers: [String], warnings: [String]) {
        var blockers: [String] = []
        var warnings: [String] = []

        let drive = facts.drive
        let finalName = sanitizedName(facts.requestedName, format: facts.format)

        // MARK: Blockers

        // 1. Never the source. This is the one rule, restated for the one
        //    operation in the app that isn't a copy.
        //
        //    Checked two ways because they fail differently. Same volume is the
        //    obvious mistake. Same *physical disk* is the subtle one: erasing the
        //    whole disk takes every partition on it, so a source sitting on
        //    another slice of the same stick would be destroyed by an erase that
        //    named a different volume.
        if let sourcePath = facts.sourceVolumePath, sourcePath == drive.volumeURL.path {
            blockers.append(
                "“\(drive.name)” is the drive you're copying from. ThumbPrint never writes to the source, and erasing it is not an exception."
            )
        } else if let sourceDisk = facts.sourceWholeDiskBSDName,
                  let thisDisk = drive.wholeDiskBSDName,
                  sourceDisk == thisDisk {
            blockers.append(
                "“\(drive.name)” is on the same physical disk as the drive you're copying from. Erasing rewrites the whole disk, so the source would go with it."
            )
        }

        // 2. No physical disk resolved, so there is nothing to hand `diskutil`.
        if drive.wholeDiskBSDName == nil {
            blockers.append(
                "macOS didn't report a disk device for “\(drive.name)”, so ThumbPrint can't erase it. Use Disk Utility instead."
            )
        }

        // 3. Write-protected media can't be erased, and finding out halfway is
        //    worse than finding out now.
        if drive.isReadOnly {
            blockers.append(
                "“\(drive.name)” is read-only. Check the drive's physical write-protect switch, if it has one."
            )
        }

        // 4. FAT32 above its addressable ceiling. `newfs_msdos` would refuse —
        //    after `diskutil` had already rewritten the partition map, leaving a
        //    disk with no filesystem at all.
        if facts.format == .fat32, facts.wholeDiskSize > DiskFormat.fat32MaximumCapacity {
            blockers.append(
                "FAT32 can't address a disk this large (\(ByteFormat.string(facts.wholeDiskSize)), limit \(ByteFormat.string(DiskFormat.fat32MaximumCapacity))). Choose exFAT."
            )
        }

        // 5. A disk image selected for this copy that lives on the drive being
        //    erased. Same class of mistake as `ImagePreflight`'s containment
        //    rule, and the same component-wise test, so “/Volumes/HOT” doesn't
        //    appear to contain “/Volumes/HOTFIRE/backup.sparseimage”.
        for imageURL in facts.selectedImageURLs
        where ImagePreflight.volume(drive.volumeURL.path, contains: imageURL) {
            blockers.append(
                "The disk image “\(imageURL.lastPathComponent)” is on “\(drive.name)”. Erasing the drive would delete it. Choose a different drive, or move the image first."
            )
        }

        // MARK: Warnings

        // Always said, always first: this is the sentence the user is here to
        // read, and it is the only one that can't be undone.
        warnings.append(
            "Everything on “\(drive.name)” will be permanently erased — \(ByteFormat.string(drive.usedCapacity)) in use of \(ByteFormat.string(drive.totalCapacity)). This can't be undone."
        )

        // Other partitions on the same physical disk. The user picked a volume;
        // what actually gets rewritten is the disk under it.
        let others = facts.siblings.filter { !isTheSameVolume($0, as: drive) }
        if !others.isEmpty {
            let names = others.map(\.displayName).joined(separator: ", ")
            warnings.append(
                "This disk carries \(others.count) other partition\(others.count == 1 ? "" : "s") — \(names). Erasing rewrites the whole disk, so \(others.count == 1 ? "it goes" : "they go") too."
            )
        }

        // Phrased as "4 GB" rather than formatted from the real 2^32 ceiling,
        // which `ByteFormat` renders as "4.29 GB" — accurate, and not how anyone
        // says it. Matches `ImagePreflight`'s wording for the same limit.
        if facts.format == .fat32 {
            warnings.append(
                "FAT32 can't store a single file larger than 4 GB. A DJ library never gets close; a video file might."
            )
        }

        if finalName != facts.requestedName {
            warnings.append(
                "\(facts.format.title) allows \(facts.format.volumeNameLimit) characters from a restricted set, so the drive will be named “\(finalName)”."
            )
        }

        return (blockers, warnings)
    }

    // MARK: - Approval

    /// The only way to obtain an `EraseApproval`, and it returns `nil` whenever
    /// `evaluate` produced a blocker.
    static func approve(_ facts: Facts) -> EraseApproval? {
        guard evaluate(facts).blockers.isEmpty else { return nil }
        // Re-derived rather than trusted: `evaluate`'s blocker for a missing BSD
        // name and this guard have to agree, and this is the one that decides
        // whether a subprocess runs.
        guard let bsdName = facts.drive.wholeDiskBSDName else { return nil }

        return EraseApproval(
            wholeDiskBSDName: bsdName,
            format: facts.format,
            volumeName: sanitizedName(facts.requestedName, format: facts.format),
            driveName: facts.drive.name,
            previousVolumePath: facts.drive.volumeURL.path
        )
    }

    // MARK: - Helpers

    /// Reuses the image feature's sanitizer rather than growing a second one:
    /// the constraints are the filesystem's, not the container's, and that
    /// function is already pinned by the harness.
    static func sanitizedName(_ name: String, format: DiskFormat) -> String {
        DiskImageStore.sanitizedVolumeName(from: name, filesystem: format.diskutilName)
    }

    /// A sibling entry and the chosen drive are the same partition when their
    /// device identifiers match. `Drive` doesn't carry its slice identifier, so
    /// the volume name is the fallback — good enough for a warning, and the
    /// warning over-reports rather than under-reports if it's wrong.
    private static func isTheSameVolume(_ sibling: SiblingVolume, as drive: Drive) -> Bool {
        if let name = sibling.volumeName, !name.isEmpty, name == drive.name { return true }
        return false
    }
}

/// Permission to erase one physical disk, in one format, under one name.
///
/// Only `FormatPreflight.approve(_:)` can make one — the initializer is
/// `fileprivate` to this file — and it refuses whenever a blocker applies. That
/// is what makes `DriveFormatter.erase(_:)`'s signature a guarantee rather than
/// a convention.
struct EraseApproval: Equatable {
    let wholeDiskBSDName: String
    let format: DiskFormat
    let volumeName: String

    /// Carried for messages only. The volume's path stops existing the moment
    /// the erase begins.
    let driveName: String
    let previousVolumePath: String

    fileprivate init(
        wholeDiskBSDName: String,
        format: DiskFormat,
        volumeName: String,
        driveName: String,
        previousVolumePath: String
    ) {
        self.wholeDiskBSDName = wholeDiskBSDName
        self.format = format
        self.volumeName = volumeName
        self.driveName = driveName
        self.previousVolumePath = previousVolumePath
    }

    var deviceNode: String { "/dev/\(wholeDiskBSDName)" }
}
