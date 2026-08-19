import Foundation

struct CloneSummary {
    var mode: CloneMode
    var sourceName: String
    var targetName: String
    var duration: TimeInterval
    var filesCopied = 0
    var bytesCopied: Int64 = 0
    var itemsDeleted = 0
    var foldersCreated = 0
    var skipped: [String] = []
    var verification: VerificationReport?

    var succeededCleanly: Bool {
        skipped.isEmpty && (verification?.passed ?? true)
    }
}

/// The two live volumes for one run, plus everything that must be released when
/// it ends.
///
/// This is where a disk image stops being a file and becomes a drive. Every
/// engine downstream — `FileSyncEngine`, `Verifier`, `PreflightReport` — sees
/// only the two `Drive` values, which is why adding image support required no
/// change to any of them.
struct JobSession {
    let source: Drive
    let target: Drive
    let attachments: [DiskImageStore.Attachment]

    /// The image file involved, if any, and which side it sat on.
    let imageURL: URL?
    let imageDirection: ImagePreflight.Direction?

    /// Set only when *this* run created the image file, so backing out of
    /// preflight can remove a file the user never got a backup into.
    let createdImageURL: URL?

    /// Turns the two chosen endpoints into two mounted volumes.
    ///
    /// Nothing here is privileged — see `DiskImageStore`.
    ///
    /// The read-only flag is derived mechanically from *which side the image is
    /// on*, never passed in by a caller. A source image is therefore always
    /// mounted read-only, and there is no code path that can opt out of that.
    /// That is the restore direction's proof of the one rule.
    static func resolve(source: Endpoint, target: Endpoint) throws -> JobSession {
        var attachments: [DiskImageStore.Attachment] = []
        var createdImageURL: URL?

        // Release anything already attached if a later step throws. Registered
        // before each attach, the same ordering lesson as `BlockCloneEngine`'s
        // pre-registered remount: a failure on the second must not strand the
        // first with no route back.
        func releaseAll() {
            for attachment in attachments.reversed() { DiskImageStore.detach(attachment) }
        }

        do {
            let sourceDrive: Drive
            switch source {
            case .drive(let drive):
                sourceDrive = drive
            case .image(let url):
                let mountPoint = try DiskImageStore.makeMountPoint()
                let attachment = try DiskImageStore.attach(url, readOnly: true, mountPoint: mountPoint)
                attachments.append(attachment)
                sourceDrive = try DiskImageStore.drive(for: attachment)
            }

            let targetDrive: Drive
            switch target {
            case .drive(let drive):
                targetDrive = drive
            case .image(let url):
                var imageURL = url
                if !FileManager.default.fileExists(atPath: url.path) {
                    // A new image takes the source drive's format and its whole
                    // capacity, so it can hold everything the source ever will
                    // and never needs a resize macOS can't perform on FAT.
                    guard let filesystem = DiskImageStore.filesystemArgument(
                        matching: sourceDrive.formatDescription
                    ) else {
                        throw DiskImageStore.Failure.unsupportedFormat(sourceDrive.formatDescription)
                    }
                    imageURL = try DiskImageStore.create(
                        at: url,
                        sizeBytes: DiskImageStore.recommendedSize(for: sourceDrive),
                        filesystem: filesystem,
                        volumeName: sourceDrive.name
                    )
                    createdImageURL = imageURL
                }

                let mountPoint = try DiskImageStore.makeMountPoint()
                let attachment = try DiskImageStore.attach(imageURL, readOnly: false, mountPoint: mountPoint)
                attachments.append(attachment)
                targetDrive = try DiskImageStore.drive(for: attachment)
            }

            return JobSession(
                source: sourceDrive,
                target: targetDrive,
                attachments: attachments,
                imageURL: source.imageURL ?? target.imageURL,
                imageDirection: source.isImage ? .restore : (target.isImage ? .save : nil),
                createdImageURL: createdImageURL
            )
        } catch {
            releaseAll()
            throw error
        }
    }

    /// The facts `ImagePreflight` needs, gathered from the volume that actually
    /// holds the image file rather than the volume inside it.
    func imageFacts(bytesToCopy: Int64) -> ImagePreflight.Facts? {
        guard let imageURL, let imageDirection else { return nil }

        let host = imageURL.deletingLastPathComponent()
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey,
        ]
        let values = try? host.resourceValues(forKeys: keys)

        // The drive is whichever side isn't the image.
        let drive = imageDirection == .save ? source : target
        let imageVolume = imageDirection == .save ? target : source

        return ImagePreflight.Facts(
            direction: imageDirection,
            imageURL: imageURL,
            imageDisplayName: imageURL.lastPathComponent,
            hostFormatDescription: values?.volumeLocalizedFormatDescription ?? "",
            hostAvailableCapacity: Int64(values?.volumeAvailableCapacity ?? 0),
            bytesToCopy: bytesToCopy,
            endpointVolumes: [
                .init(name: drive.name, path: drive.volumeURL.path)
            ],
            imageFormatDescription: imageVolume.formatDescription,
            driveFormatDescription: drive.formatDescription,
            driveName: drive.name
        )
    }

    func release() {
        for attachment in attachments.reversed() { DiskImageStore.detach(attachment) }
    }
}

/// Owns the source/target selection and runs the clone through its phases.
@MainActor
@Observable
final class CloneJob {
    enum Phase {
        case idle
        case analyzing
        case preflight(PreflightReport)
        /// Terminal state for `.compareOnly`. Deliberately not `preflight` —
        /// there is no Start button on the far side of a comparison.
        case comparison(ComparisonReport)
        case running
        case finished(CloneSummary)
        case failed(String)
        case cancelled
    }

    var mode: CloneMode = .fastSync

    /// What the user picked, which may be a drive or a disk image file. These are
    /// resolved into two mounted `Drive`s at the top of `analyze()`; past that
    /// point the rest of this class, and every engine, deals only in `Drive`.
    var source: Endpoint?
    var target: Endpoint?

    private(set) var phase: Phase = .idle
    private(set) var progress = CloneProgress()

    /// Set when an interrupted run left the backup drive in a state that looks
    /// healthier than it is. Surfaced by `SummaryView` on the cancelled and
    /// failed screens.
    private(set) var targetWarning: String?

    private var task: Task<Void, Never>?
    private var cachedPlan: SyncPlan?
    private var cachedSourceIndex: FileIndex?

    /// The mounted volumes this run is actually operating on, established during
    /// analysis and held until the job reaches a terminal phase.
    ///
    /// `start()` reads its volumes from here rather than from `source`/`target`,
    /// so the drives that were preflighted are provably the drives that get
    /// written to.
    private var session: JobSession?

    var sourceDisplayName: String { source?.displayName ?? "Source" }
    var targetDisplayName: String { target?.displayName ?? "Backup" }

    var canAnalyze: Bool {
        guard let source, let target, source.id != target.id else { return false }
        // Exact Clone copies raw blocks between device nodes; an image is a file.
        // Refused here as well as in the picker so the rule holds even if the UI
        // ever offers the combination by accident.
        if !mode.allowsImageEndpoints, source.isImage || target.isImage { return false }
        return true
    }

    var isBusy: Bool {
        switch phase {
        case .analyzing, .running: return true
        default: return false
        }
    }

    // MARK: - Phase 1: read-only analysis

    func analyze() {
        guard let sourceEndpoint = source, let targetEndpoint = target, canAnalyze else { return }
        let mode = self.mode

        phase = .analyzing
        progress = CloneProgress()
        cachedPlan = nil
        cachedSourceIndex = nil
        targetWarning = nil

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Resolve whatever the user picked into two mounted volumes.
                // Below this line nothing knows an image was involved: `source`
                // and `target` are ordinary `Drive`s, exactly as they were before
                // images existed.
                if sourceEndpoint.isImage || targetEndpoint.isImage {
                    await self.setStage(
                        .preparingImage,
                        item: (sourceEndpoint.imageURL ?? targetEndpoint.imageURL)?.lastPathComponent ?? ""
                    )
                }

                let session = try JobSession.resolve(source: sourceEndpoint, target: targetEndpoint)
                await self.adopt(session)
                try Task.checkCancellation()

                let source = session.source
                let target = session.target

                switch mode {
                case .fastSync:
                    let engine = FileSyncEngine { progress in
                        Task { @MainActor in self.progress = progress }
                    }
                    let (plan, sourceIndex, targetIndex) = try engine.makePlan(source: source, target: target)
                    try Task.checkCancellation()

                    // Deliberately after indexing rather than before: the check
                    // unmounts and remounts the source, and an index taken
                    // either side of that is identical because the check never
                    // writes. Doing it first would only mean racing the remount.
                    //
                    // Skipped entirely when the source is a disk image, and that
                    // is a correctness fix rather than an optimisation:
                    // `FilesystemCheck` confirms the volume came back by testing
                    // its *original* mount path, and macOS remounts a detached
                    // image at /Volumes/<name>, not at the private `-mountpoint`
                    // it was attached to. `volumeRemounted` would go false and
                    // raise a hard blocker on a perfectly good image. `hdiutil
                    // attach` already refuses a structurally unreadable image,
                    // which is the check that actually matters for a file.
                    let filesystemCheck: FilesystemCheck.Report
                    if sourceEndpoint.isImage {
                        // `.passed` rather than the default `.inconclusive`,
                        // which would raise a warning naming a "source drive"
                        // that doesn't exist here. It is also the truthful
                        // verdict: a structurally damaged sparse image does not
                        // attach at all, and we only reach this line because it
                        // did.
                        filesystemCheck = FilesystemCheck.Report(outcome: .passed)
                    } else {
                        await self.setStage(.checkingSource, item: source.name)
                        filesystemCheck = FilesystemCheck.verify(
                            volumeURL: source.volumeURL,
                            isCancelled: { Task.isCancelled }
                        )
                    }
                    try Task.checkCancellation()

                    let report = PreflightReport.fastSync(
                        source: source,
                        target: target,
                        plan: plan,
                        sourceIndex: sourceIndex,
                        targetIndex: targetIndex,
                        filesystemCheck: filesystemCheck,
                        image: session.imageFacts(bytesToCopy: plan.bytesToCopy)
                    )
                    await self.finishAnalysis(plan: plan, sourceIndex: sourceIndex, report: report)

                case .exactClone:
                    await self.setStage(.checkingSource, item: source.name)
                    let filesystemCheck = FilesystemCheck.verify(
                        volumeURL: source.volumeURL,
                        isCancelled: { Task.isCancelled }
                    )
                    try Task.checkCancellation()

                    let report = PreflightReport.exactClone(
                        source: source,
                        target: target,
                        filesystemCheck: filesystemCheck
                    )
                    await self.finishAnalysis(plan: nil, sourceIndex: nil, report: report)

                case .compareOnly:
                    // Only the read-only half of the engine is used: `makePlan`
                    // builds an index of each volume and diffs them in memory.
                    // The `SyncPlan` it also returns is discarded — a comparison
                    // needs "missing" and "different" kept apart, which is what
                    // `FileIndex.compare` produces.
                    //
                    // No `FilesystemCheck` here, deliberately. It unmounts and
                    // remounts the volume, which is more than an inspection
                    // should do to a drive the user is already worried about —
                    // and unlike a backup, nothing downstream depends on the
                    // filesystem being sound.
                    let engine = FileSyncEngine { progress in
                        Task { @MainActor in self.progress = progress }
                    }
                    let (_, leftIndex, rightIndex) = try engine.makePlan(source: source, target: target)
                    try Task.checkCancellation()

                    let report = ComparisonReport.make(
                        left: source,
                        right: target,
                        leftIndex: leftIndex,
                        rightIndex: rightIndex
                    )
                    await self.finishComparison(
                        report,
                        leftIndex: leftIndex,
                        rightIndex: rightIndex
                    )
                }
            } catch is CancellationError {
                await self.setPhase(.idle)
            } catch {
                await self.setPhase(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Phase 2: the destructive part

    func start() {
        // Compare has no destructive phase to start. Refused here rather than
        // handled downstream so that the one entry point to writing anything
        // states the exclusion outright.
        guard !mode.isInspection else { return }
        // The volumes come from the session established during analysis, not from
        // `source`/`target`: the drives that were preflighted are the drives that
        // get written to, even if the picker's selection changed underneath.
        guard let session else { return }
        let source = session.source
        let target = session.target
        // Named for what the user picked, so a summary says "HOTFIRE.sparseimage"
        // rather than the volume name buried inside the image.
        let sourceLabel = sourceDisplayName
        let targetLabel = targetDisplayName
        let mode = self.mode
        let plan = cachedPlan
        let sourceIndex = cachedSourceIndex
        let startedAt = Date()

        phase = .running
        progress = CloneProgress()
        targetWarning = nil

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let summary: CloneSummary

                switch mode {
                case .fastSync:
                    guard let plan, let sourceIndex else {
                        throw CloneError.cannotReadVolume(source.name)
                    }

                    let engine = FileSyncEngine { progress in
                        Task { @MainActor in self.progress = progress }
                    }
                    let result = try engine.execute(
                        plan: plan,
                        source: source,
                        target: target,
                        sourceIndex: sourceIndex
                    )

                    try Task.checkCancellation()
                    await self.beginVerification()

                    let verification = try Verifier.verify(
                        sourceIndex: sourceIndex,
                        targetVolume: target.volumeURL,
                        skipped: result.skipped,
                        isCancelled: { Task.isCancelled },
                        onCount: { count in
                            // Verification walks the whole tree; forwarding
                            // every single file would flood the main actor the
                            // same way an unthrottled copy would.
                            guard count % 200 == 0 else { return }
                            Task { @MainActor in self.progress.itemsCompleted = count }
                        }
                    )

                    summary = CloneSummary(
                        mode: .fastSync,
                        sourceName: sourceLabel,
                        targetName: targetLabel,
                        duration: Date().timeIntervalSince(startedAt),
                        filesCopied: result.filesCopied,
                        bytesCopied: result.bytesCopied,
                        itemsDeleted: result.itemsDeleted,
                        foldersCreated: result.foldersCreated,
                        skipped: result.skipped + result.unreadableOnSource.map { "\($0) — unreadable on source" },
                        verification: verification
                    )

                case .exactClone:
                    let engine = BlockCloneEngine { progress in
                        Task { @MainActor in self.progress = progress }
                    }
                    let result = try engine.run(source: source, target: target)

                    summary = CloneSummary(
                        mode: .exactClone,
                        sourceName: sourceLabel,
                        targetName: targetLabel,
                        duration: Date().timeIntervalSince(startedAt),
                        bytesCopied: result.bytesCopied,
                        verification: nil
                    )

                case .compareOnly:
                    // Unreachable — refused by the guard at the top of `start`.
                    // Present so that adding a future write-capable mode has to
                    // come back here and say what it writes.
                    return
                }

                await self.recordCompletedSync(
                    source: source,
                    target: target,
                    summary: summary,
                    sourceIndex: sourceIndex
                )
                await self.setPhase(.finished(summary))
                await Notifier.shared.cloneFinished(summary)

            } catch is CancellationError {
                await self.finishInterrupted(.cancelled, mode: mode)
            } catch {
                await self.finishInterrupted(.failed(error.localizedDescription), mode: mode)
                await Notifier.shared.cloneFailed(
                    targetName: targetLabel,
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Control

    func cancel() {
        task?.cancel()
    }

    func reset() {
        task?.cancel()
        task = nil
        cachedPlan = nil
        cachedSourceIndex = nil
        progress = CloneProgress()
        targetWarning = nil
        // Backing out of preflight without ever running: the image file we made
        // this run holds nothing, so remove it rather than leave a mystery behind.
        // A file that existed before this run is never touched.
        releaseSession(deletingCreatedImage: true)
        phase = .idle
    }

    /// Called when a drive disappears while a picker selection references it.
    ///
    /// An image endpoint is a file, not a volume, so it survives drives coming and
    /// going — it's dropped only if the file itself is gone.
    func dropMissingDrives(available: [Drive]) {
        let ids = Set(available.map(\.id))

        func stillValid(_ endpoint: Endpoint?) -> Bool {
            switch endpoint {
            case .none: return true
            case .drive(let drive): return ids.contains(drive.id)
            case .image(let url): return FileManager.default.fileExists(atPath: url.path)
            }
        }

        if !stillValid(source) { source = nil }
        if !stillValid(target) { target = nil }
    }

    // MARK: - Session lifetime

    private func adopt(_ newSession: JobSession) {
        session = newSession
    }

    /// Releases any mounted image, on every path out of a run.
    ///
    /// Funnelled through `setPhase` rather than a `defer` because the attachment
    /// spans two separate detached Tasks — analysis and the copy — with the
    /// preflight screen in between, so no single scope covers its lifetime.
    /// Idempotent, so calling it more than once is free.
    private func releaseSession(deletingCreatedImage: Bool = false) {
        guard let session else { return }
        session.release()

        if deletingCreatedImage, let created = session.createdImageURL {
            try? FileManager.default.removeItem(at: created)
        }

        self.session = nil
    }

    // MARK: - MainActor transitions

    private func setPhase(_ newPhase: Phase) {
        switch newPhase {
        case .idle, .comparison, .finished, .failed, .cancelled:
            // Terminal for this run: let the image go. The file stays; only the
            // mount is released.
            releaseSession()
        case .analyzing, .preflight, .running:
            break
        }
        phase = newPhase
    }

    private func setStage(_ stage: CloneProgress.Stage, item: String = "") {
        progress.stage = stage
        progress.currentItem = item
        progress.itemsCompleted = 0
        progress.itemsTotal = 0
        progress.bytesCompleted = 0
        progress.bytesTotal = 0
    }

    /// A Fast Sync that stops partway leaves a partial mirror, which the next
    /// run simply finishes — the generic "incomplete, run it again" copy covers
    /// it. A raw clone is different: killing `dd` mid-stream leaves the target
    /// holding a fragment of the source's partition map and filesystem, and it
    /// will often still mount and present as a working DJ drive. That looks
    /// healthier than it is, so it gets said out loud.
    ///
    /// Saving to an image is the one file-level case that does need saying. The
    /// partial mirror is still harmless and the next save finishes it — but the
    /// image now *looks* like a complete backup, and the danger is restoring from
    /// it in six months believing it was one.
    private func finishInterrupted(_ newPhase: Phase, mode: CloneMode) {
        if mode == .exactClone, progress.stage == .rawCopying {
            let name = target?.displayName ?? "The backup drive"
            targetWarning = """
            “\(name)” now holds only part of the source's partition map and filesystem. It may still mount and look like a working drive, but its contents can't be trusted and it may not load in a CDJ.

            Run the Exact Clone again to completion, or erase the drive in Disk Utility, before using it.
            """
        } else if let imageURL = target?.imageURL, progress.stage == .copying || progress.stage == .deleting {
            targetWarning = """
            “\(imageURL.lastPathComponent)” is an incomplete copy — the save stopped part-way through. It will open normally and look like a finished backup, so don't restore from it as it stands.

            Run the save again to the same file to finish it; only what's missing gets copied.
            """
        }
        setPhase(newPhase)
    }

    /// Compare is a dead end by design: nothing is cached, because there is no
    /// second step that could use it.
    ///
    /// It does still teach the registry something — a comparison is the only
    /// operation that indexes *both* drives and keeps neither, so it's the one
    /// chance to record what's on a drive that is never the source of a backup.
    private func finishComparison(
        _ report: ComparisonReport,
        leftIndex: FileIndex,
        rightIndex: FileIndex
    ) {
        cachedPlan = nil
        cachedSourceIndex = nil

        // Only drives get a registry entry. A mounted image does have a volume
        // UUID, so recording it would silently work — and then the registry would
        // hold a row nothing can ever display, whose "last seen" only moves when
        // the image happens to be opened. An image's identity is its path, and
        // paths move.
        if source?.isImage != true {
            DriveRegistry.shared.noteContents(report.left, index: leftIndex)
        }
        if target?.isImage != true {
            DriveRegistry.shared.noteContents(report.right, index: rightIndex)
        }

        setPhase(.comparison(report))
    }

    /// Records a finished copy in the registry.
    ///
    /// Fast Sync only. An Exact Clone reproduces the source's volume identity on
    /// the target — docs/DEVELOPMENT.md warns that macOS may then show two drives with the
    /// same name — so the target's pre-clone UUID stops describing the drive the
    /// moment the clone succeeds. Recording against it would leave the registry
    /// asserting something false about a drive that no longer exists as such.
    ///
    /// Nothing here can fail in a way the user needs to hear about: the registry
    /// swallows its own write errors, and this runs after the copy is complete
    /// and verified.
    private func recordCompletedSync(
        source: Drive,
        target: Drive,
        summary: CloneSummary,
        sourceIndex: FileIndex?
    ) {
        guard summary.mode == .fastSync else { return }

        // A run involving an image records only the drive's side, for the reason
        // given in `finishComparison`. Unlike Exact Clone this *is* recorded: a
        // file-level mirror doesn't reproduce the source's volume identity, so
        // nothing about the drive's own UUID stops being true.
        if let imageURL = self.session?.imageURL, let direction = self.session?.imageDirection {
            DriveRegistry.shared.noteImageSync(
                drive: direction == .save ? source : target,
                role: direction == .save ? .source : .backup,
                imageURL: imageURL,
                filesCopied: summary.filesCopied,
                bytesCopied: summary.bytesCopied,
                duration: summary.duration,
                verified: summary.succeededCleanly,
                sourceIndex: sourceIndex
            )
            return
        }

        DriveRegistry.shared.noteSync(
            source: source,
            target: target,
            filesCopied: summary.filesCopied,
            bytesCopied: summary.bytesCopied,
            duration: summary.duration,
            // A run with skipped files or a failed verification is not a
            // dependable backup, and the registry shouldn't later claim it was.
            verified: summary.succeededCleanly,
            sourceIndex: sourceIndex
        )
    }

    private func finishAnalysis(plan: SyncPlan?, sourceIndex: FileIndex?, report: PreflightReport) {
        cachedPlan = plan
        cachedSourceIndex = sourceIndex
        phase = .preflight(report)
    }

    private func beginVerification() {
        progress.stage = .verifying
        progress.itemsCompleted = 0
        progress.itemsTotal = 0
        progress.bytesTotal = 0
        progress.bytesCompleted = 0
        progress.currentItem = ""
    }
}
