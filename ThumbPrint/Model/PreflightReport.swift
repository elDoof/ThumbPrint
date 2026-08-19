import Foundation

/// Everything the user needs to decide whether to let the clone proceed.
///
/// This is the only route to the Start button. Nothing has been written to the
/// target at the point this is shown — computing it is strictly read-only.
struct PreflightReport {
    let mode: CloneMode
    let source: Drive
    let target: Drive

    var filesToCopy = 0
    var bytesToCopy: Int64 = 0
    var foldersToCreate = 0
    var itemsToDelete = 0
    var bytesToDelete: Int64 = 0

    /// Exact Clone only: the full physical disk size that will be written.
    var diskSizeToClone: Int64 = 0

    var blockers: [String] = []
    var warnings: [String] = []

    /// Set when the source shows filesystem damage, so the UI can offer a route
    /// to Disk Utility. ThumbPrint never repairs the source itself — writing to
    /// the source is the one thing this app must never do.
    var sourceNeedsRepair = false

    /// The disk image file behind an endpoint, when that endpoint is an image
    /// rather than a drive. `source`/`target` above still hold ordinary `Drive`
    /// values — a mounted image *is* a mounted volume — so these exist only so the
    /// UI can name the file instead of the volume inside it.
    var sourceImage: URL?
    var targetImage: URL?

    var isSavingToImage: Bool { targetImage != nil }
    var isRestoringFromImage: Bool { sourceImage != nil }

    var canProceed: Bool { blockers.isEmpty }

    var isNoOp: Bool {
        mode == .fastSync && filesToCopy == 0 && itemsToDelete == 0 && foldersToCreate == 0
    }

    /// What actually gets written, for the headline figure.
    var bytesToWrite: Int64 {
        mode == .exactClone ? diskSizeToClone : bytesToCopy
    }
}

// MARK: - Fast Sync

extension PreflightReport {
    static func fastSync(
        source: Drive,
        target: Drive,
        plan: SyncPlan,
        sourceIndex: FileIndex,
        targetIndex: FileIndex,
        filesystemCheck: FilesystemCheck.Report,
        image: ImagePreflight.Facts? = nil
    ) -> PreflightReport {
        var report = PreflightReport(mode: .fastSync, source: source, target: target)

        report.filesToCopy = plan.filesToCopy.count
        report.bytesToCopy = plan.bytesToCopy
        report.foldersToCreate = plan.directoriesToCreate.count
        report.itemsToDelete = plan.itemsToDelete.count
        report.bytesToDelete = plan.itemsToDelete.reduce(0) { $0 + $1.size }

        // MARK: Blockers

        if source.id == target.id {
            report.blockers.append("The source and the backup drive are the same volume.")
        }

        if target.isReadOnly {
            report.blockers.append("“\(target.name)” is read-only. Check the drive's physical write-protect switch, if it has one.")
        }

        // A source that indexes as empty is far more likely to be a failed read
        // — a flaky drive, a dismounted volume, a permissions problem — than a
        // genuine instruction to erase the backup. Mirroring it would delete
        // everything on the target, so refuse rather than warn.
        if sourceIndex.fileCount == 0 && targetIndex.fileCount > 0 {
            report.blockers.append(
                "“\(source.name)” appears to be empty, but “\(target.name)” holds \(targetIndex.fileCount) file\(targetIndex.fileCount == 1 ? "" : "s"). Continuing would erase the backup. Check that the source drive is working and fully mounted."
            )
        }

        // Filesystem damage on the source. Screened from the index that was
        // just built, so it costs nothing extra and never touches the drive.
        // Copying a damaged filesystem only produces a damaged backup, so this
        // blocks rather than warns.
        let health = SourceHealthReport.evaluate(index: sourceIndex, drive: source)
        if !health.isHealthy {
            report.sourceNeedsRepair = true
            report.blockers.append(contentsOf: health.findings)
        }

        // The metadata screen above can only see damage that reaches file
        // metadata, which lets whole classes of corruption through — a
        // cross-linked cluster chain or a directory entry that no longer
        // describes a directory both look perfectly normal in an index. This is
        // the OS's own checker, and where the two disagree it is the authority.
        switch filesystemCheck.outcome {
        case .passed:
            break

        case .damaged(let detail):
            report.sourceNeedsRepair = true
            report.blockers.append("The filesystem on “\(source.name)” is damaged:\n\(detail)")

        case .inconclusive(let reason):
            // Couldn't check is not the same as found nothing, and saying
            // otherwise would be the exact false reassurance this check exists
            // to remove.
            report.warnings.append(
                "ThumbPrint couldn't finish verifying the filesystem on “\(source.name)” (\(reason)), so it can't rule out damage that a backup would faithfully copy."
            )
        }

        // Appended once, after every damage finding, so the two screens can't
        // produce two copies of the same instruction.
        if report.sourceNeedsRepair {
            report.blockers.append(
                "Repair “\(source.name)” with Disk Utility before backing it up. ThumbPrint won't repair it for you — it never writes to the source drive."
            )
        }

        if !filesystemCheck.volumeRemounted {
            report.blockers.append(
                "“\(source.name)” didn't come back after the filesystem check. Unplug it, plug it in again, and retry."
            )
        }

        // Same reasoning, one step softer: if part of the source couldn't be
        // read AND that would translate into deletions on the backup, the
        // deletions are probably an artefact of the read failure.
        if !sourceIndex.unreadablePaths.isEmpty && report.itemsToDelete > 0 {
            report.blockers.append(
                "\(sourceIndex.unreadablePaths.count) item\(sourceIndex.unreadablePaths.count == 1 ? "" : "s") on “\(source.name)” couldn't be read, and \(report.itemsToDelete) item\(report.itemsToDelete == 1 ? "" : "s") would be deleted from the backup. Those deletions may just be files ThumbPrint failed to see. Fix the source drive first."
            )
        }

        // Deletions run first and overwrites release their old blocks, so both
        // count toward what will actually be available during the copy.
        let reclaimedByOverwrite = plan.filesToCopy.reduce(Int64(0)) { total, entry in
            total + (targetIndex.entries[entry.relativePath]?.size ?? 0)
        }
        let effectivelyAvailable = target.availableCapacity + report.bytesToDelete + reclaimedByOverwrite

        if report.bytesToCopy > effectivelyAvailable {
            report.blockers.append(
                "Not enough space on “\(target.name)”. Needs \(ByteFormat.string(report.bytesToCopy)), will have \(ByteFormat.string(effectivelyAvailable)) available."
            )
        }

        // MARK: Warnings

        if report.itemsToDelete > 0 {
            report.warnings.append(
                "\(report.itemsToDelete) item\(report.itemsToDelete == 1 ? "" : "s") on “\(target.name)” (\(ByteFormat.string(report.bytesToDelete))) will be permanently deleted because they're no longer on the source."
            )
        }

        // Whether the source's exported library still describes its own audio.
        // Derived from the index that was just built, so it costs nothing and
        // touches nothing. Warnings only, deliberately: a stale library is a
        // condition of the source, and a backup faithfully reproducing it is
        // correct behaviour — see `LibraryReport.notes(for:)`.
        report.warnings.append(
            contentsOf: LibraryReport.evaluate(index: sourceIndex).notes(for: source)
        )

        // A target full of files that share nothing with the source is almost
        // certainly the wrong drive.
        let overlap = targetIndex.entries.keys.filter { sourceIndex.entries[$0] != nil }.count
        if targetIndex.fileCount > 0 && overlap == 0 {
            report.warnings.append(
                "“\(target.name)” contains \(targetIndex.fileCount) file\(targetIndex.fileCount == 1 ? "" : "s") and none of them match the source. Double-check this is the right backup drive."
            )
        }

        if source.formatDescription != target.formatDescription {
            report.warnings.append(
                "Different formats: source is \(source.formatDescription), backup is \(target.formatDescription)."
            )
        }

        if !target.isFATFamily {
            report.warnings.append(
                "“\(target.name)” is \(target.formatDescription). DJ players generally expect exFAT — the copy will work, but the drive may not be readable by a CDJ."
            )
        }

        if !sourceIndex.unreadablePaths.isEmpty {
            let count = sourceIndex.unreadablePaths.count
            report.warnings.append(
                "\(count) item\(count == 1 ? "" : "s") on the source couldn't be read and won't be copied."
            )
        }

        // The image-specific rules, if either side is one. Appended rather than
        // interleaved so that every rule above stays exactly as it was for the
        // drive-to-drive case, and so the image rules can live in a value type the
        // test harness compiles — this file isn't in it.
        if let image {
            report.sourceImage = image.direction == .restore ? image.imageURL : nil
            report.targetImage = image.direction == .save ? image.imageURL : nil

            let (imageBlockers, imageWarnings) = ImagePreflight.evaluate(image)
            report.blockers.append(contentsOf: imageBlockers)
            report.warnings.append(contentsOf: imageWarnings)
        }

        return report
    }
}

// MARK: - Exact Clone

extension PreflightReport {
    static func exactClone(
        source: Drive,
        target: Drive,
        filesystemCheck: FilesystemCheck.Report
    ) -> PreflightReport {
        var report = PreflightReport(mode: .exactClone, source: source, target: target)

        if source.id == target.id {
            report.blockers.append("The source and the backup drive are the same volume.")
            return report
        }

        // A raw clone reproduces damaged structures byte for byte, so a broken
        // source matters at least as much here as it does for Fast Sync.
        switch filesystemCheck.outcome {
        case .passed:
            break

        case .damaged(let detail):
            report.sourceNeedsRepair = true
            report.blockers.append("The filesystem on “\(source.name)” is damaged:\n\(detail)")
            report.blockers.append(
                "An Exact Clone copies the damage too, byte for byte. Repair “\(source.name)” with Disk Utility first — ThumbPrint never writes to the source drive."
            )

        case .inconclusive(let reason):
            report.warnings.append(
                "ThumbPrint couldn't finish verifying the filesystem on “\(source.name)” (\(reason)), so it can't rule out damage this clone would reproduce exactly."
            )
        }

        if !filesystemCheck.volumeRemounted {
            report.blockers.append(
                "“\(source.name)” didn't come back after the filesystem check. Unplug it, plug it in again, and retry."
            )
        }

        guard let sourceBSD = source.wholeDiskBSDName, let targetBSD = target.wholeDiskBSDName else {
            report.blockers.append(CloneError.exactCloneUnavailable.localizedDescription)
            return report
        }

        do {
            let sourceSize = try BlockCloneEngine.wholeDiskSize(bsdName: sourceBSD)
            let targetSize = try BlockCloneEngine.wholeDiskSize(bsdName: targetBSD)
            report.diskSizeToClone = sourceSize

            if targetSize < sourceSize {
                report.blockers.append(
                    CloneError.targetTooSmall(needed: sourceSize, available: targetSize).localizedDescription
                )
            } else if targetSize > sourceSize {
                report.warnings.append(
                    "“\(target.name)” is larger than the source (\(ByteFormat.string(targetSize)) vs \(ByteFormat.string(sourceSize))). The extra space will be unusable until you repartition the drive."
                )
            }
        } catch {
            report.blockers.append(error.localizedDescription)
            return report
        }

        report.warnings.append(
            "Everything on “\(target.name)” will be erased, including its partition layout."
        )

        report.warnings.append(
            "The whole disk is copied, used space or not — \(ByteFormat.string(report.diskSizeToClone)) will be written even though only \(ByteFormat.string(source.usedCapacity)) is in use."
        )

        report.warnings.append(
            "The copy will carry the source's volume identity, so with both drives plugged in macOS may show two drives named “\(source.name)”. That's expected."
        )

        report.warnings.append("Both drives will be unmounted during the clone, and an administrator password is required.")

        return report
    }
}
