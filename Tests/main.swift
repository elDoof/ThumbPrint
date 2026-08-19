import Foundation

// Test harness for the two new roadmap features, following docs/DEVELOPMENT.md § Testing:
// the engine/model sources are Foundation-only, so they compile standalone and
// can be driven against real filesystems on disk images.
//
// argv: <exfat-src> <exfat-dst> <fresh-library-dir> <no-library-dir>

func makeDrive(_ path: String, name: String) -> Drive {
    Drive(
        volumeURL: URL(fileURLWithPath: path),
        name: name,
        wholeDiskBSDName: nil,
        totalCapacity: 200_000_000,
        availableCapacity: 100_000_000,
        volumeUUID: nil,
        formatDescription: "ExFAT",
        isReadOnly: false
    )
}

var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  PASS  \(label)")
    } else {
        print("  FAIL  \(label) — \(detail())")
        failures += 1
    }
}

do {
    let srcPath = CommandLine.arguments[1]
    let dstPath = CommandLine.arguments[2]
    let freshPath = CommandLine.arguments[3]
    let noLibPath = CommandLine.arguments[4]

    let srcDrive = makeDrive(srcPath, name: "TP-SRC")
    let dstDrive = makeDrive(dstPath, name: "TP-DST")

    let srcIndex = try FileIndex.build(at: srcDrive.volumeURL)
    let dstIndex = try FileIndex.build(at: dstDrive.volumeURL)

    print("\n=== A. Export staleness (stale library on exFAT) ===")
    let lib = LibraryReport.evaluate(index: srcIndex)
    print("  indexed \(srcIndex.fileCount) files, counted \(lib.audioFileCount) as audio")

    // Measured, not assumed: on exFAT, FileManager's enumerator does not yield
    // `._` files at all — they exist and `fileExists`/`resourceValues` resolve
    // them, but neither `enumerator` nor `contentsOfDirectory` returns them. So
    // the sidecar is absent from the index before `isAudio` ever sees it. The
    // `._` guard in `isAudio` is exercised on APFS in section C instead.
    check("3 audio files on exFAT (sidecar never enters the index)",
          lib.audioFileCount == 3, "got \(lib.audioFileCount)")
    check("sidecar absent from the exFAT index entirely",
          srcIndex.entries["Contents/._New Track.mp3"] == nil,
          "got \(srcIndex.entries["Contents/._New Track.mp3"]!)")
    check("rekordbox library detected", lib.library(.rekordbox) != nil)
    check("no Serato library detected", lib.library(.serato) == nil)
    check("library reported stale", lib.staleLibraries.count == 1,
          "got \(lib.staleLibraries.count)")

    if let rb = lib.library(.rekordbox) {
        let paths = rb.newerAudio.map(\.relativePath).sorted()
        print("  newer than export.pdb: \(paths)")
        check("exactly 1 track newer than export.pdb", rb.newerAudio.count == 1, "got \(paths)")
        check("the newer track is the right one",
              rb.newerAudio.first?.relativePath == "Contents/New Track.mp3",
              "got \(rb.newerAudio.first?.relativePath ?? "nil")")
    }

    let notes = lib.notes(for: srcDrive)
    for note in notes { print("  note: \(note)") }
    check("one note produced", notes.count == 1, "got \(notes.count)")
    check("note states the gap as 9 days", notes.first?.contains("9 days") ?? false,
          "got \(notes.first ?? "nil")")
    check("note names the database path",
          notes.first?.contains("PIONEER/rekordbox/export.pdb") ?? false)

    print("\n=== B. Fresh library (export newer than all audio) ===")
    let freshIndex = try FileIndex.build(at: URL(fileURLWithPath: freshPath))
    let fresh = LibraryReport.evaluate(index: freshIndex)
    check("library detected", fresh.library(.rekordbox) != nil)
    check("not reported stale", fresh.staleLibraries.isEmpty,
          "got \(fresh.staleLibraries.count)")
    check("no notes", fresh.notes(for: makeDrive(freshPath, name: "TP-FRESH")).isEmpty)

    print("\n=== C. Audio but no library ===")
    let noLibIndex = try FileIndex.build(at: URL(fileURLWithPath: noLibPath))
    let noLib = LibraryReport.evaluate(index: noLibIndex)
    check("no library detected", !noLib.hasLibrary)
    check("audio detected", noLib.hasAudio, "count \(noLib.audioFileCount)")
    // Measured: the enumerator hides `._` files on APFS as well, so this is not
    // a FAT quirk — FileManager filters AppleDouble everywhere. The `._` guard
    // in `isAudio` is therefore unreachable through `FileIndex.build` today; it
    // is kept as insurance against a future change of indexing mechanism, not
    // because it currently does work.
    check("sidecar hidden from the APFS index too",
          noLibIndex.entries["Contents/._track.mp3"] == nil,
          "got \(String(describing: noLibIndex.entries["Contents/._track.mp3"]))")
    check("audio count is 1", noLib.audioFileCount == 1, "got \(noLib.audioFileCount)")
    let noLibNotes = noLib.notes(for: makeDrive(noLibPath, name: "TP-NOLIB"))
    for note in noLibNotes { print("  note: \(note)") }
    check("one note produced", noLibNotes.count == 1, "got \(noLibNotes.count)")
    check("note says no library",
          noLibNotes.first?.contains("no rekordbox or Serato library") ?? false)

    print("\n=== D. Two-way compare (real exFAT, ±2s tolerance) ===")
    let cmp = FileIndex.compare(left: srcIndex, right: dstIndex)
    print("  onlyOnLeft:  \(cmp.onlyOnLeft.map(\.relativePath))")
    print("  onlyOnRight: \(cmp.onlyOnRight.map(\.relativePath))")
    print("  differing:   \(cmp.differing.map(\.relativePath))")
    print("  identical:   \(cmp.identicalCount)")

    let left = Set(cmp.onlyOnLeft.map(\.relativePath))
    let right = Set(cmp.onlyOnRight.map(\.relativePath))
    let differing = Set(cmp.differing.map(\.relativePath))

    check("export.pdb is left-only", left.contains("PIONEER/rekordbox/export.pdb"))
    check("new track is left-only", left.contains("Contents/New Track.mp3"))
    check("sidecar appears in no bucket — it was never indexed on either side",
          !left.contains("Contents/._New Track.mp3")
            && !right.contains("Contents/._New Track.mp3")
            && !differing.contains("Contents/._New Track.mp3"))
    check("extra file is right-only", right.contains("Contents/Extra.mp3"))
    check("size-changed file reported as differing", differing == ["Contents/Shared.mp3"],
          "got \(differing)")
    check("byte-identical file with matching mtime counted identical",
          cmp.identicalCount >= 1, "got \(cmp.identicalCount)")
    check("identical file is not in any difference bucket",
          !left.contains("Contents/Old Track.mp3")
            && !right.contains("Contents/Old Track.mp3")
            && !differing.contains("Contents/Old Track.mp3"))
    check("not reported as identical overall", !cmp.isIdentical)
    check("differenceCount adds up",
          cmp.differenceCount == cmp.onlyOnLeft.count + cmp.onlyOnRight.count + cmp.differing.count)

    print("\n=== E. ComparisonReport notes ===")
    let report = ComparisonReport.make(
        left: srcDrive,
        right: dstDrive,
        leftIndex: srcIndex,
        rightIndex: dstIndex
    )
    for note in report.notes { print("  note: \(note)") }
    check("library asymmetry reported",
          report.notes.contains { $0.contains("has a rekordbox library") && $0.contains("doesn't") })
    check("source staleness carried through",
          report.notes.contains { $0.contains("newer than its rekordbox library") })
    check("not identical", !report.isIdentical)
    check("no unreadable paths", report.unreadable.isEmpty, "got \(report.unreadable)")

    print("\n=== F. Identical-drive compare (self vs self) ===")
    let selfCmp = FileIndex.compare(left: srcIndex, right: srcIndex)
    check("a drive compared with itself is identical", selfCmp.isIdentical)
    check("all files counted identical", selfCmp.identicalCount == srcIndex.fileCount,
          "\(selfCmp.identicalCount) vs \(srcIndex.fileCount)")

    print("\n=== G. Drive registry ===")
    let regDir = URL(fileURLWithPath: CommandLine.arguments[5], isDirectory: true)
    try? FileManager.default.removeItem(at: regDir)
    try FileManager.default.createDirectory(at: regDir, withIntermediateDirectories: true)
    let regURL = regDir.appendingPathComponent("drives.json")

    // Whole-second timestamps on purpose: the store encodes dates as ISO 8601,
    // which carries no fractional seconds, so a `Date()` with a fraction would
    // not survive a round trip byte-for-byte. Harmless for a sighting time,
    // fatal for a test asserting equality.
    let t0 = Date(timeIntervalSince1970: 1_775_000_000)
    let t1 = t0.addingTimeInterval(3600)

    let uuidA = "AAAAAAAA-0000-0000-0000-000000000001"
    let uuidB = "BBBBBBBB-0000-0000-0000-000000000002"

    func testDrive(_ uuid: String?, name: String, capacity: Int64 = 128_000_000_000) -> Drive {
        Drive(
            volumeURL: URL(fileURLWithPath: "/Volumes/\(name)"),
            name: name,
            wholeDiskBSDName: nil,
            totalCapacity: capacity,
            availableCapacity: 1,
            volumeUUID: uuid,
            formatDescription: "ExFAT",
            isReadOnly: false
        )
    }

    var store = DriveRegistryStore()
    store.noteSeen(testDrive(uuidA, name: "GIG"), at: t0)
    check("new drive recorded", store.driveCount == 1)
    check("firstSeen == lastSeen on a first sighting",
          store.records[uuidA]?.firstSeen == t0 && store.records[uuidA]?.lastSeen == t0)

    store.noteSeen(testDrive(uuidA, name: "GIG-RENAMED", capacity: 256_000_000_000), at: t1)
    check("same UUID does not create a second record", store.driveCount == 1)
    check("firstSeen preserved across sightings", store.records[uuidA]?.firstSeen == t0)
    check("lastSeen advanced", store.records[uuidA]?.lastSeen == t1)
    check("a rename is picked up", store.records[uuidA]?.name == "GIG-RENAMED")
    check("capacity refreshed", store.records[uuidA]?.totalCapacity == 256_000_000_000)

    store.noteSeen(testDrive(nil, name: "NO-UUID"), at: t1)
    check("a drive with no volume UUID is not tracked", store.driveCount == 1)

    store.noteContents(testDrive(uuidA, name: "GIG-RENAMED"), index: srcIndex, at: t1)
    if let snap = store.records[uuidA]?.contents {
        check("snapshot file count matches the index", snap.fileCount == srcIndex.fileCount,
              "\(snap.fileCount) vs \(srcIndex.fileCount)")
        check("snapshot records the library found", snap.libraries == ["rekordbox"],
              "got \(snap.libraries)")
        check("snapshot carries a database mtime", snap.newestDatabaseModified != nil)
    } else {
        check("snapshot recorded", false, "contents was nil")
    }

    store.noteSync(
        source: testDrive(uuidA, name: "GIG"), target: testDrive(uuidB, name: "BACKUP"),
        filesCopied: 42, bytesCopied: 1_400_000_000, duration: 100,
        verified: true, sourceIndex: srcIndex, at: t1
    )
    check("source side recorded as .source", store.records[uuidA]?.lastSync?.role == .source)
    check("backup side recorded as .backup", store.records[uuidB]?.lastSync?.role == .backup)
    check("source names the backup", store.records[uuidA]?.lastSync?.otherDriveName == "BACKUP")
    check("backup names the source", store.records[uuidB]?.lastSync?.otherDriveName == "GIG")
    check("a verified mirror gives the target the source's snapshot",
          store.records[uuidB]?.contents == store.records[uuidA]?.contents)
    check("throughput derives from duration",
          store.records[uuidA]?.lastSync?.averageBytesPerSecond == 14_000_000,
          "got \(store.records[uuidA]?.lastSync?.averageBytesPerSecond ?? -1)")

    var unverified = DriveRegistryStore()
    unverified.noteSync(
        source: testDrive(uuidA, name: "GIG"), target: testDrive(uuidB, name: "BACKUP"),
        filesCopied: 5, bytesCopied: 10, duration: 1,
        verified: false, sourceIndex: srcIndex, at: t1
    )
    check("an unverified run still records the attempt",
          unverified.records[uuidB]?.lastSync?.verified == false)
    check("an unverified run leaves the target snapshot unset",
          unverified.records[uuidB]?.contents == nil)
    check("an unverified run still snapshots the source",
          unverified.records[uuidA]?.contents != nil)

    try store.save(to: regURL)
    let reloaded = DriveRegistryStore.load(from: regURL)
    check("round trip preserves every record", reloaded.records == store.records,
          "\(reloaded.driveCount) drives back")
    check("round trip preserves dates exactly", reloaded.records[uuidA]?.lastSeen == t1)
    check("a reloaded store is writable", reloaded.canSave)

    try "not json at all".data(using: .utf8)!.write(to: regURL)
    let afterCorrupt = DriveRegistryStore.load(from: regURL)
    check("a corrupt file yields an empty store", afterCorrupt.driveCount == 0)
    let setAside = ((try? FileManager.default.contentsOfDirectory(atPath: regDir.path)) ?? [])
        .filter { $0.contains("unreadable") }
    check("the corrupt file is moved aside, not deleted", setAside.count == 1, "found \(setAside)")
    check("the corrupt file is no longer in place",
          !FileManager.default.fileExists(atPath: regURL.path))

    let fromTheFuture = #"{"version": 999, "drives": []}"#
    try fromTheFuture.data(using: .utf8)!.write(to: regURL)
    let futureStore = DriveRegistryStore.load(from: regURL)
    check("a newer schema loads no records", futureStore.driveCount == 0)
    check("a newer schema refuses to save", !futureStore.canSave)
    try futureStore.save(to: regURL)
    check("saving left the newer file byte-identical",
          (try? String(contentsOf: regURL, encoding: .utf8)) == fromTheFuture)

    // =========================================================================
    print("\n=== H. DiskImageStore, against real hdiutil ===")
    // =========================================================================

    let imagesDir = URL(fileURLWithPath: CommandLine.arguments[6])

    // Sizing and naming: pure rules, but the arithmetic is the kind that is
    // silently wrong for years. `-size ...b` means SECTORS, not bytes — asking
    // for 128e9 "b" builds a 65 TB image — which is why sizeArgument exists.
    check("size argument is whole MiB",
          DiskImageStore.sizeArgument(bytes: 1_048_576) == "1m",
          DiskImageStore.sizeArgument(bytes: 1_048_576))
    check("size argument rounds up, never down",
          DiskImageStore.sizeArgument(bytes: 1_048_577) == "2m",
          DiskImageStore.sizeArgument(bytes: 1_048_577))
    check("a 128 GB drive asks for at least 122071 MiB",
          (Int(DiskImageStore.sizeArgument(bytes: 128_000_000_000).dropLast()) ?? 0) >= 122_071)

    check("exFAT maps to hdiutil's ExFAT",
          DiskImageStore.filesystemArgument(matching: "ExFAT") == "ExFAT")
    check("FAT32 maps to hdiutil's MS-DOS FAT32",
          DiskImageStore.filesystemArgument(matching: "MS-DOS (FAT32)") == "MS-DOS FAT32")
    check("APFS has no image filesystem",
          DiskImageStore.filesystemArgument(matching: "APFS") == nil)

    check("a FAT32 volume name is capped at 11 characters",
          DiskImageStore.sanitizedVolumeName(from: "A Very Long Drive Name", filesystem: "MS-DOS FAT32").count == 11)
    check("illegal volume-name characters are stripped",
          !DiskImageStore.sanitizedVolumeName(from: "HOT:FIRE/2026", filesystem: "ExFAT").contains(":"))
    check("an unusable name falls back rather than producing an empty label",
          DiskImageStore.sanitizedVolumeName(from: "///", filesystem: "ExFAT") == "THUMBPRINT")

    // Create → attach → Drive.
    let imageURL = imagesDir.appendingPathComponent("backup.sparseimage")
    let created = try DiskImageStore.create(
        at: imageURL, sizeBytes: 120 * 1024 * 1024, filesystem: "ExFAT", volumeName: "TP-IMG"
    )
    check("create makes the file", FileManager.default.fileExists(atPath: created.path))

    let createdInfo = try DiskImageStore.info(for: created)
    check("a created image reports itself sparse", createdInfo.isSparse, createdInfo.format)
    check("a sparse image costs far less than its virtual size",
          createdInfo.fileSize < createdInfo.virtualSize / 10,
          "file \(createdInfo.fileSize) vs virtual \(createdInfo.virtualSize)")

    check("a non-image file is refused",
          (try? DiskImageStore.info(for: URL(fileURLWithPath: srcPath + "/Contents/Old Track.mp3"))) == nil)

    let rwPoint = try DiskImageStore.makeMountPoint()
    let rwAttachment = try DiskImageStore.attach(created, readOnly: false, mountPoint: rwPoint)
    check("attach reports a dev entry", rwAttachment.devEntry.hasPrefix("/dev/"), rwAttachment.devEntry)
    check("attach mounts where it was told",
          FileManager.default.fileExists(atPath: rwAttachment.mountPoint.path))

    let imageDrive = try DiskImageStore.drive(for: rwAttachment)
    check("the mounted image reads back as exFAT",
          imageDrive.isFATFamily, imageDrive.formatDescription)
    check("an image never offers Exact Clone", !imageDrive.supportsExactClone)

    // The claim the whole picker safety story rests on: a `-nobrowse` image at a
    // private mount point is invisible to the volume enumeration DriveScanner
    // uses, so it can never be offered as a drive.
    let visibleVolumes = FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
    ) ?? []
    check("a mounted image is absent from mountedVolumeURLs",
          !visibleVolumes.contains { $0.path == rwAttachment.mountPoint.path },
          visibleVolumes.map(\.path).joined(separator: ", "))

    check("attaching an already-attached image is refused",
          (try? DiskImageStore.attach(created, readOnly: false,
                                      mountPoint: try DiskImageStore.makeMountPoint())) == nil)
    check("attachment(for:) finds an open image",
          DiskImageStore.attachment(for: created) != nil)

    check("detach releases it", DiskImageStore.detach(rwAttachment))
    check("attachment(for:) no longer finds it",
          DiskImageStore.attachment(for: created) == nil)

    // =========================================================================
    print("\n=== I. Read-only attach: the restore direction's proof ===")
    // =========================================================================

    let roPoint = try DiskImageStore.makeMountPoint()
    let roAttachment = try DiskImageStore.attach(created, readOnly: true, mountPoint: roPoint)
    let roDrive = try DiskImageStore.drive(for: roAttachment)

    check("a read-only image reports itself read-only", roDrive.isReadOnly)

    // Kernel enforcement, not a code path we can opt out of. This is what makes
    // "restore can't write to the image" a guarantee rather than an intention.
    let forbidden = roAttachment.mountPoint.appendingPathComponent("should-not-appear.txt")
    check("writing to a read-only image throws",
          (try? Data("x".utf8).write(to: forbidden)) == nil)
    check("nothing was created", !FileManager.default.fileExists(atPath: forbidden.path))

    DiskImageStore.detach(roAttachment)

    // =========================================================================
    print("\n=== J. Save to an image, and restore out of it ===")
    // =========================================================================

    let savePoint = try DiskImageStore.makeMountPoint()
    let saveAttachment = try DiskImageStore.attach(created, readOnly: false, mountPoint: savePoint)
    let saveTarget = try DiskImageStore.drive(for: saveAttachment)

    let engine = FileSyncEngine { _ in }
    let (savePlan, saveSourceIndex, _) = try engine.makePlan(source: srcDrive, target: saveTarget)
    let saveResult = try engine.execute(
        plan: savePlan, source: srcDrive, target: saveTarget, sourceIndex: saveSourceIndex
    )
    check("saving to the image copied every source file",
          saveResult.filesCopied == saveSourceIndex.fileCount,
          "copied \(saveResult.filesCopied) of \(saveSourceIndex.fileCount)")

    let saveVerification = try Verifier.verify(
        sourceIndex: saveSourceIndex, targetVolume: saveTarget.volumeURL, skipped: saveResult.skipped
    )
    check("the saved image verifies", saveVerification.passed,
          saveVerification.firstProblems(limit: 3).joined(separator: "; "))

    check("the library folder survived into the image",
          FileManager.default.fileExists(
              atPath: savePoint.appendingPathComponent("PIONEER/rekordbox/export.pdb").path))

    // The ±2s FAT mtime regression, now across the drive→image boundary. A
    // strict comparison here would silently re-copy the whole library every run.
    let (secondPlan, _, _) = try engine.makePlan(source: srcDrive, target: saveTarget)
    check("saving again copies nothing", secondPlan.filesToCopy.isEmpty,
          "would re-copy \(secondPlan.filesToCopy.count)")
    check("saving again deletes nothing", secondPlan.itemsToDelete.isEmpty)

    // A stray file inside the image is an orphan the mirror must remove.
    try Data("junk".utf8).write(to: savePoint.appendingPathComponent("Contents/Stray.mp3"))
    let (strayPlan, straySourceIndex, _) = try engine.makePlan(source: srcDrive, target: saveTarget)
    check("a file only in the image is scheduled for deletion",
          strayPlan.itemsToDelete.count == 1,
          strayPlan.itemsToDelete.map(\.relativePath).joined(separator: ", "))
    _ = try engine.execute(plan: strayPlan, source: srcDrive, target: saveTarget,
                           sourceIndex: straySourceIndex)

    DiskImageStore.detach(saveAttachment)

    // Restore: the image is now the SOURCE, so it is attached read-only.
    let imageBytesBefore = (try? Data(contentsOf: created).count) ?? -1
    let restorePoint = try DiskImageStore.makeMountPoint()
    let restoreAttachment = try DiskImageStore.attach(created, readOnly: true, mountPoint: restorePoint)
    let restoreSource = try DiskImageStore.drive(for: restoreAttachment)

    let (restorePlan, restoreIndex, _) = try engine.makePlan(source: restoreSource, target: dstDrive)
    check("restoring removes what the image doesn't have",
          restorePlan.itemsToDelete.contains { $0.relativePath.contains("Extra.mp3") },
          restorePlan.itemsToDelete.map(\.relativePath).joined(separator: ", "))

    let restoreResult = try engine.execute(
        plan: restorePlan, source: restoreSource, target: dstDrive, sourceIndex: restoreIndex
    )
    let restoreVerification = try Verifier.verify(
        sourceIndex: restoreIndex, targetVolume: dstDrive.volumeURL, skipped: restoreResult.skipped
    )
    check("the restored drive verifies", restoreVerification.passed,
          restoreVerification.firstProblems(limit: 3).joined(separator: "; "))
    check("the restored drive has the library",
          FileManager.default.fileExists(atPath: dstPath + "/PIONEER/rekordbox/export.pdb"))
    check("the orphan is gone from the restored drive",
          !FileManager.default.fileExists(atPath: dstPath + "/Contents/Extra.mp3"))

    DiskImageStore.detach(restoreAttachment)
    check("the image file was not written during the restore",
          (try? Data(contentsOf: created).count) == imageBytesBefore)

    // Reaping: an attachment nobody released, exactly as an app crash leaves it.
    let orphanPoint = try DiskImageStore.makeMountPoint()
    _ = try DiskImageStore.attach(created, readOnly: true, mountPoint: orphanPoint)
    check("an abandoned mount is still attached before reaping",
          DiskImageStore.attachment(for: created) != nil)
    check("reapStaleMounts collects it", DiskImageStore.reapStaleMounts() >= 1)
    check("nothing is attached afterwards", DiskImageStore.attachment(for: created) == nil)

    // =========================================================================
    print("\n=== K. ImagePreflight rules ===")
    // =========================================================================

    func facts(
        _ direction: ImagePreflight.Direction,
        image: String,
        hostFormat: String = "APFS",
        hostFree: Int64 = 500_000_000_000,
        bytes: Int64 = 1_000_000,
        volumes: [ImagePreflight.VolumeRef] = []
    ) -> ImagePreflight.Facts {
        ImagePreflight.Facts(
            direction: direction,
            imageURL: URL(fileURLWithPath: image),
            imageDisplayName: URL(fileURLWithPath: image).lastPathComponent,
            hostFormatDescription: hostFormat,
            hostAvailableCapacity: hostFree,
            bytesToCopy: bytes,
            endpointVolumes: volumes,
            imageFormatDescription: "ExFAT",
            driveFormatDescription: "ExFAT",
            driveName: "HOTFIRE"
        )
    }

    let clean = ImagePreflight.evaluate(facts(.save, image: "/Users/dj/Backups/HOTFIRE.sparseimage"))
    check("a sane save has no blockers", clean.blockers.isEmpty,
          clean.blockers.joined(separator: " | "))

    // The one-rule guard: the image must not live on either drive in the copy.
    let onSource = ImagePreflight.evaluate(facts(
        .save,
        image: "/Volumes/HOTFIRE/backup.sparseimage",
        volumes: [.init(name: "HOTFIRE", path: "/Volumes/HOTFIRE")]
    ))
    check("saving onto the drive being read is blocked", !onSource.blockers.isEmpty)

    let onTarget = ImagePreflight.evaluate(facts(
        .restore,
        image: "/Volumes/HOTFIRE/backup.sparseimage",
        volumes: [.init(name: "HOTFIRE", path: "/Volumes/HOTFIRE")]
    ))
    check("restoring from an image on the target drive is blocked", !onTarget.blockers.isEmpty)

    // Containment is component-wise, or /Volumes/HOT would appear to contain
    // everything under /Volumes/HOTFIRE.
    check("a prefix that isn't a path component doesn't count as containment",
          !ImagePreflight.volume("/Volumes/HOT",
                                 contains: URL(fileURLWithPath: "/Volumes/HOTFIRE/x.sparseimage")))
    check("a genuine parent volume does count as containment",
          ImagePreflight.volume("/Volumes/HOTFIRE",
                                contains: URL(fileURLWithPath: "/Volumes/HOTFIRE/x.sparseimage")))

    check("a FAT32 host is blocked over the 4 GB file limit",
          !ImagePreflight.evaluate(facts(.save, image: "/Volumes/USB/b.sparseimage",
                                         hostFormat: "MS-DOS (FAT32)")).blockers.isEmpty)
    check("an exFAT host is fine",
          ImagePreflight.evaluate(facts(.save, image: "/Volumes/BIG/b.sparseimage",
                                        hostFormat: "ExFAT")).blockers.isEmpty)

    check("too little room where the file lives is blocked",
          !ImagePreflight.evaluate(facts(.save, image: "/Users/dj/b.sparseimage",
                                         hostFree: 1_000_000, bytes: 900_000_000)).blockers.isEmpty)
    check("enough room is not blocked",
          ImagePreflight.evaluate(facts(.save, image: "/Users/dj/b.sparseimage",
                                        hostFree: 900_000_000_000, bytes: 900_000_000)).blockers.isEmpty)

    check("a restore explains that it won't rename the drive",
          ImagePreflight.evaluate(facts(.restore, image: "/Users/dj/b.sparseimage"))
              .warnings.contains { $0.contains("rename") })

    check("selection refuses a FAT32 location up front",
          ImagePreflight.selectionRefusal(
              imageURL: URL(fileURLWithPath: "/Volumes/USB/b.sparseimage"),
              hostFormatDescription: "MS-DOS (FAT32)", mountedVolumes: []) != nil)
    check("selection accepts an ordinary location",
          ImagePreflight.selectionRefusal(
              imageURL: URL(fileURLWithPath: "/Users/dj/b.sparseimage"),
              hostFormatDescription: "APFS", mountedVolumes: []) == nil)

    // =========================================================================
    print("\n=== L. Registry: image syncs ===")
    // =========================================================================

    var imageStore = DriveRegistryStore()
    let djDrive = testDrive(uuidA, name: "HOTFIRE")
    let savedImage = URL(fileURLWithPath: "/Users/dj/Backups/HOTFIRE-2026-08.sparseimage")

    imageStore.noteImageSync(
        drive: djDrive, role: .source, imageURL: savedImage,
        filesCopied: 12, bytesCopied: 5_000, duration: 10, verified: true, at: t0
    )
    check("only the drive gets a record, never the image", imageStore.driveCount == 1,
          "\(imageStore.driveCount) records")
    check("the drive's role is source when saving",
          imageStore.record(for: djDrive)?.lastSync?.role == .source)
    check("the image path is recorded",
          imageStore.record(for: djDrive)?.lastSync?.imagePath == savedImage.path)
    check("the history line names the image without its extension",
          imageStore.record(for: djDrive)?.lastSync?.otherDriveName == "HOTFIRE-2026-08")

    var restoreStore = DriveRegistryStore()
    let freshStick = testDrive(uuidB, name: "NEWSTICK")
    restoreStore.noteImageSync(
        drive: freshStick, role: .backup, imageURL: savedImage,
        filesCopied: 12, bytesCopied: 5_000, duration: 10, verified: false, at: t1
    )
    check("the drive's role is backup when restoring",
          restoreStore.record(for: freshStick)?.lastSync?.role == .backup)
    check("an unverified restore records the attempt",
          restoreStore.record(for: freshStick)?.lastSync?.verified == false)

    // Forward compatibility: a record written before disk images existed has no
    // imagePath key at all, and must still decode.
    let legacy = """
    {"version":1,"drives":[{"volumeUUID":"\(uuidA)","name":"HOTFIRE","formatDescription":"ExFAT",\
    "totalCapacity":128000000000,"firstSeen":"2026-08-01T12:00:00Z","lastSeen":"2026-08-01T12:00:00Z",\
    "lastSync":{"finishedAt":"2026-08-01T12:00:00Z","role":"source","otherDriveName":"BACKUPDJ",\
    "filesCopied":10,"bytesCopied":100,"duration":5,"verified":true}}]}
    """
    let legacyURL = imagesDir.appendingPathComponent("legacy.json")
    try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
    let legacyStore = DriveRegistryStore.load(from: legacyURL)
    check("a record written before disk images still loads", legacyStore.driveCount == 1)
    check("its imagePath is simply absent",
          legacyStore.record(for: djDrive)?.lastSync?.imagePath == nil)
    check("and the store stays writable", legacyStore.canSave)

    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
    exit(failures == 0 ? 0 : 1)
} catch {
    print("harness error: \(error)")
    exit(2)
}
