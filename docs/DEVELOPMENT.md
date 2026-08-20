# ThumbPrint — development notes

A macOS app that copies one USB drive onto another. Its only purpose is making backup copies of a DJ drive (Rekordbox/Serato library on exFAT or FAT32).

Two modes, chosen per run:
- **Fast Sync** — file-level mirror. Copies only what changed; deletes from the backup anything no longer on the source. The everyday path.
- **Exact Clone** — bit-for-bit `dd` of the whole disk, behind the standard macOS admin prompt.

A backup drive can also be **erased** from the picker before it's copied to, and the app **checks GitHub for its own updates** once a day.

---

## Where this stands

Read this first if you're picking the project up cold.

- **Git:** public at `elDoof/ThumbPrint` on GitHub, branch `main`, MIT licensed. **1.0 shipped 2026-08-19** — release `v1.0` carries a notarized `ThumbPrint-1.0.dmg`. History was squashed to a single authored commit for the public release and the old repository was deleted and recreated rather than force-pushed, so no earlier object survives on GitHub. The pre-release history exists only on the local branch `archive/pre-public-history`. No CI; releases are cut by hand with `Scripts/release.sh`. **The tree is at 1.1** — erasing a backup drive and the in-app update check, both built and tested on 2026-08-19 but not yet released. Cutting `v1.1` is also what makes the update check do anything observable: 1.0 has nothing newer to find.
- **Distribution:** signed with `Developer ID Application: Sascha Nowlin (DPLC4BD7ST)` and notarized under the `djsnowlin@gmail.com` Apple account. The Xcode project stays ad-hoc signed so a fork builds with no certificate; the Developer ID, hardened runtime and secure timestamp are applied only by `Scripts/release.sh`.
- **Tests:** `./Tests/run.sh` is the suite (194 checks). It builds its own throwaway exFAT volumes and disk images, runs, and cleans up after itself. Run it before and after touching `Model/` or `Services/`.
- **Built and covered by tests:** Fast Sync, Exact Clone (code only — see below), export-staleness screening, Compare mode, the drive registry, disk image save/restore, erasing a backup drive, and the update check.
- **Next on the roadmap:** the pre-gig readiness check, then library-aware verification. Both described under [Roadmap](#roadmap), including what the second one must verify before any `.pdb` parsing is written.
- **Never verified against real hardware:** Exact Clone — still the main open risk. Erasing is next after it: the harness runs a real `diskutil eraseDisk` against a throwaway disk image, which is the same command against a device node, but no USB stick has been through it and no erased stick has then been loaded in a CDJ. The update feature's every piece is proven — the live GitHub fetch, the pinned signature check accepting the shipped 1.0 and rejecting an unrelated Apple app, the version pin, and a real bundle swap against a scratch copy of the app using the real notarized DMG — but **nobody has clicked Install and Relaunch in the running app**, because 1.0 is still the newest release and there is nothing to update to. Disk image save/restore is close behind: heavily covered by the harness against real `hdiutil` images, but never once against a DJ stick or a large library. Also unproven in the running app: the drive registry's picker line and its Application Support file, Compare against two *large* real libraries, and **the picker's disk-image rows, its two file panels, and the image preflight wording** — the engine path below them has 60 checks, the UI above them has none.
- **Two soft assumptions are recorded rather than hidden**, both in [Roadmap](#roadmap): `LibraryReport.staleTolerance` (whether an export writes its database before or after the audio was never measured), and the `.pdb`/Serato format claims, which are community reverse-engineering and must be checked against the live `HOTFIRE` tree before anything is built on them.

---

## Build and run

`xcode-select` on the development machine points at the **Command Line Tools**, not Xcode. Every build must set `DEVELOPER_DIR` explicitly. **Do not run `sudo xcode-select -s`** — that is a global change to the machine for no benefit here.

```bash
./Scripts/build.sh            # Debug build, then launch
./Scripts/build.sh release    # Release build, then launch
./Scripts/build.sh install    # Release build → /Applications, then launch

# or directly:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ThumbPrint.xcodeproj -scheme ThumbPrint -configuration Debug build
```

### Cutting a release

```bash
./Scripts/release.sh                # build → sign → notarize → staple → DMG → notarize → staple → verify
./Scripts/release.sh --no-notarize  # sign and package only, for a local smoke test
```

Output is `dist/ThumbPrint-<version>.dmg`. Bump `MARKETING_VERSION` in `project.pbxproj` (both configurations) first;
the script reads the version from the built bundle, so the filename and the DMG volume name follow automatically.
Then `gh release create v<version> dist/ThumbPrint-<version>.dmg --title "ThumbPrint <version>" --notes-file <file>`.

**The release is now also the update feed**, so three things about it are load-bearing rather than cosmetic:

- **The tag must parse as a version.** `AppVersion` accepts `v1.1`, `1.1`, `1.1.2`; it does not accept `nightly`, and `UpdateRelease.parse` refuses the whole feed rather than guessing.
- **A `.dmg` must be attached.** No asset, no update — the app says so instead of silently doing nothing. If more than one `.dmg` is attached the one naming the version wins.
- **The notes are shown verbatim in the app.** `--notes-file` content lands in the update sheet as Markdown, so write it for the person deciding whether to install, not for a changelog.

Drafts and pre-releases are ignored by `releases/latest` and refused again by the parser, so a draft can be staged safely.

Notarization needs a keychain profile named `ThumbPrint`, stored once with an app-specific password from
appleid.apple.com under the `djsnowlin@gmail.com` Apple account:

```bash
xcrun notarytool store-credentials "ThumbPrint" \
    --apple-id "djsnowlin@gmail.com" --team-id "DPLC4BD7ST" --password "<app-specific-password>"
```

`--no-notarize` deliberately skips the Gatekeeper assertion at the end, because `spctl` rejects a Developer ID build
that has no ticket yet — that is the expected state of that mode, not a failure.

`project.pbxproj` is hand-written (no XcodeGen or Tuist in this project) using **`objectVersion = 77`** with a `PBXFileSystemSynchronizedRootGroup`. The project references the `ThumbPrint/` **directory**, not individual files — so **adding a `.swift` file requires no project edit**. Drop it in and build.

`Config/Info.plist` and `Config/ThumbPrint.entitlements` deliberately live *outside* `ThumbPrint/`. Anything inside that folder is auto-added to the Resources build phase, which would duplicate the plist into the bundle.

---

## The one rule

**ThumbPrint must never write to the source drive.** Everything else is negotiable; this is not. It's what makes the app trustworthy, and it has been proven three ways (static audit, read-only-mount test, byte-level before/after snapshot).

Concretely:
- Every write destination derives from `target.volumeURL`. The source is touched only by `FileIndex.build`, `FileHandle(forReadingFrom:)`, `destinationOfSymbolicLink`, `fileExists`, and `dd`'s `if=`.
- **Never add a repair/format/fix feature that writes to the source.** When a source is damaged, detect it, explain it, and hand off to Disk Utility (`PreflightView.openDiskUtility`). This was a deliberate design decision, not an oversight.
- **Erasing a *backup* drive, added 2026-08-19, is not an exception to that.** It is target-side only, and the refusal is structural rather than a check someone has to remember: `FormatPreflight` blocks the source's own volume *and* any volume sharing the source's physical disk, and `DriveFormatter.erase` takes an `EraseApproval` — a token only `FormatPreflight.approve` can mint, and only when nothing is blocking. There is no other way to spell the argument, so there is no unchecked entry point to add a caller to by mistake.
- `FilesystemCheck` is the one deliberate stretch of "read-only": `diskutil verifyVolume` runs `fsck_msdos -n`, which cannot write, but it *does* unmount and remount the volume. That's why it runs during analysis, before anything has been written anywhere, and why it re-checks that the volume came back.
- If you touch `FileSyncEngine` or `BlockCloneEngine`, re-run the read-only-mount test below.

---

## Architecture

```
Model/
  Drive              volume URL, whole-disk BSD name, capacity, format
  CloneMode          .fastSync | .exactClone | .compareOnly
  CloneJob           @Observable state machine; owns phases + progress
  CloneProgress      progress value type + ThroughputMeter (smoothing)
  FileIndex          relPath → (size, mtime, isDir); SyncPlan + FileComparison
  PreflightReport    blockers/warnings; the only route to the Start button
  ComparisonReport   Compare's findings; left/right, deliberately not src/target
  DriveRecord        what's remembered about a drive between launches (Codable)
  Endpoint           one end of a copy: a drive, or a .sparseimage file
  ImagePreflight     the image-only preflight rules, kept pure so they're tested
  DiskFormat         exFAT | FAT32 — diskutil's spelling, the limits, MBR
  FormatPreflight    the erase rules, and EraseApproval, the token that gates them
  AppVersion         dotted version, comparable — 1.10 is newer than 1.9
  UpdateRelease      one GitHub release parsed; the "is this newer" decision
  CloneError         user-facing error copy
Services/
  DriveScanner       volume enumeration, eligibility filter, mount watching
  FileSyncEngine     mirror sync: index → plan → delete → mkdir → copy
  BlockCloneEngine   privileged dd via osascript, SIGINFO progress
  Verifier           re-reads target, compares size + mtime to source
  SourceHealthCheck  index-derived corruption screening (fast, weak)
  FilesystemCheck    diskutil verifyVolume — the authoritative damage verdict
  LibraryCheck       rekordbox/Serato detection + export-staleness screening
  DiskImageStore     hdiutil wrapper: create/attach/detach/reap .sparseimage
  DriveRegistryStore Codable persistence for DriveRecord; owns all the rules
  DriveRegistry      @Observable main-actor wrapper; decides when to write
  DriveFormatter     diskutil eraseDisk wrapper — unprivileged, target-only
  UpdateInstaller    fetch, download, pin the signature, swap the bundle, relaunch
  UpdateController   @Observable: once-a-day check, skip-this-version memory
  Notifier           completion notification, degrades to beep
Views/
  ContentView        routes on CloneJob.phase; cross-fades between them
  DesignSystem       Metrics, .card(), .pageLayout(), PageHeader, SectionLabel,
                     CapacityBar, StatTile/StatRow, NoticeBox, AppIconBadge
  DrivePickerView / PreflightView / CloneProgressView / SummaryView
  ComparisonView     Compare's results screen; the one page with no next step
  FormatDriveView    the erase sheet, opened from the destination list
  UpdateSheet        the update sheet; six states, never on screen uninvited
  Formatting         ByteFormat, DurationFormat, AgeFormat
```

Flow: `idle → analyzing → preflight → running → verifying → finished | failed | cancelled`

Compare short-circuits that: `idle → analyzing → comparison`, and stops. It reaches no write path at all — `start()` refuses `mode.isInspection` outright, and analysis calls only `FileSyncEngine.makePlan`, which is two `FileIndex.build` calls plus an in-memory diff.

Engines run on a detached `Task` and publish progress back to the MainActor. `CloneJob` is `@MainActor @Observable`.

Erasing and updating deliberately sit **outside** that phase machine. Neither is a copy, neither has a preflight → run → verify shape, and threading them through `CloneJob` would mean every phase switch in the app growing two cases that aren't about copying anything. The erase is a sheet over the picker with its own three states; the update is a sheet the app owns, held back by `ContentView` while a copy is in flight.

---

## Load-bearing details

These look like small choices and are not. Changing them breaks the app in ways tests may not catch immediately.

**The ±2 second mtime tolerance** (`FileIndex.modificationTolerance`). exFAT *and* FAT32 store modification times at 2-second resolution, so a byte-perfect copy reads back 0–2s off its source. A strict comparison makes every run re-copy the entire library, silently destroying the point of Fast Sync. Regression test: run a sync twice, second run must copy **0 files**.

**Never pass `.skipsHiddenFiles`** to the directory enumerator. Rekordbox's `/PIONEER/` and Serato's `/_Serato_/` are hidden directories, and skipping them yields a backup that looks complete in Finder and won't load in a CDJ.

**AppleDouble `._` sidecars are never indexed, and therefore never copied.** Measured 2026-08-12 on both exFAT and APFS: `FileManager.enumerator` and `contentsOfDirectory` do not return `._`-prefixed files, although they exist on disk and `fileExists`/`resourceValues` resolve them directly — an orphaned `._Orphan.mp3` with no partner file is hidden too. This is the enumerator's own behaviour, unrelated to `.skipsHiddenFiles`, and it corrects an earlier claim here that sidecars were among the hidden files being copied. No known effect on DJ use: a real rekordbox library carries no sidecars (verified against `HOTFIRE`, cue points intact), and both drives are indexed the same way so a sync converges. But a source whose files carry macOS xattrs loses them silently, and `Verifier` reads the same index so it cannot report the gap.

**NFC normalization of relative paths.** APFS returns decomposed (NFD) filenames; exFAT stores whatever was written. Without a common form, "Beyoncé.mp3" indexes under two different keys on the two drives and re-copies forever.

**Deletions run before copies.** The target may be near full; freeing orphans first avoids a spurious out-of-space failure.

**Atomic copy via `.thumbprint-tmp-<UUID>` + rename.** An interrupted copy must never leave a truncated file that a later run accepts as valid on size alone. Leftovers need no cleanup logic — they aren't on the source, so the next mirror pass deletes them as orphans.

**The `autoreleasepool` in the chunk loop, the per-file copy loop, and `FileIndex.build`.** `FileHandle.read` returns a `Data` backed by an autoreleased `NSData`, and `FileManager`/`URL` autorelease on every call. None of these loops contain a suspension point, so the enclosing pool doesn't drain until the whole run ends. Without their own pools, memory grows **1:1 with bytes copied** — every 4 MB chunk ever read stays live. This is not a micro-optimization: it froze the machine mid-backup on 2026-08-11, with `vmmap` showing a 52.8 GB footprint across 13,441 live `MALLOC_LARGE` regions (≈ 52.6 GB ÷ 4 MB chunks) and 48.6 GB swapped. Verified after the fix: a 2 GB / 1,512-file sync peaks at **13.9 MB RSS**.

**Rekordbox cue points need no special handling — and "cue points are missing" is not a copy bug until proven otherwise.** Cue points live in ordinary files: `/PIONEER/rekordbox/export.pdb`, `exportExt.pdb`, `exportLibrary.db`, and the per-track `/PIONEER/USBANLZ/**/ANLZ0000.DAT`/`.EXT`. On a real library they carry **no xattrs and no `._` sidecars**, so a data-fork copy captures all of it. Verified 2026-08-12 against the live `HOTFIRE` tree: 18,689 files, MD5-identical after a sync, and a FAT32→FAT32 backup then loaded on an XDJ-RX3 with cue points intact.

Two false alarms were investigated on 2026-08-11/12 and **neither was a ThumbPrint fault** — recorded so the next report starts from evidence rather than a theory:
- Cue points reported missing after an interrupted run. Plausible (copies are sorted alphabetically, `Contents/` precedes `PIONEER/`, and the run died inside `Contents/`) but **never confirmed** — the drive was reformatted before it could be checked.
- Cue points reported missing on a completed FAT32→FAT32 backup. **Retracted by the user; they had transferred.**

As vendor guidance rather than an observation here: exFAT *device library* support arrived in rekordbox 6.6.2 and covers only the CDJ-3000, XDJ-XZ, and XDJ-RX3 (firmware 1.11+); older players mount an exFAT stick and play tracks while ignoring `/PIONEER/`. Matching the source's format (FAT32 for essentially every DJ drive) stays the safe default, but do **not** treat exFAT as a proven cause of anything in this project.

**All four screens share `DesignSystem.swift`.** The card treatment used to be pasted inline in four places with drifting values, which is why the screens didn't read as one app. Add new chrome there, not in a view. Two details are load-bearing: `Metrics.innerRadius` is derived (`cardRadius - cardPadding`) so nested corners stay optically parallel, and `ContentView`'s phase cross-fade needs its `.id(phaseID)` — without a change of identity SwiftUI reuses the view and animates nothing, and keying on `Phase` itself would rebuild the running screen on every progress tick.

**`AppIconBadge` reads the live bundle icon** via `NSApplication.shared.applicationIconImage` rather than a copied asset, so replacing `ThumbPrint.icns` needs no code change. It appears on the start screen only — every other screen leads with an SF Symbol that carries state (progress, success, failure) that a fixed logo can't.

**Progress is throttled** to ~12/sec in `FileSyncEngine.publish`, with stage changes always passed through and a `flush()` at the end. Unthrottled, indexing a 50k-file library queues 50k main-actor hops.

**Drive eligibility is `removable || ejectable`** — deliberately *not* `!isInternal`. Attached disk images and some USB enclosures report `internal = true` despite being removable; requiring it would show "no drives connected" with a drive plainly mounted. A built-in disk is neither removable nor ejectable, so the safety property holds. Time Machine volumes are excluded separately.

**A mounted disk image *is* a `Drive`, and that is the whole design of the image feature.** `Drive` is a plain struct of eight `let`s that a mounted volume satisfies exactly, and both `CloneJob.analyze()` and `start()` open with `guard let source, let target` as `Drive` values. So `Endpoint` (drive-or-file) is resolved into two mounted `Drive`s *once*, at the top of `analyze()`, and **nothing downstream knows an image was involved** — `FileSyncEngine`, `Verifier`, `LibraryCheck`, `SourceHealthCheck`, `ComparisonReport` and every existing rule in `PreflightReport.fastSync` were not modified. Keeping the mode as `.fastSync` also means `PreflightView`/`SummaryView`'s `mode == .fastSync` stat-tile branches stay correct. If you're tempted to thread `Endpoint` deeper than `JobSession.resolve`, that's the mistake this shape exists to avoid.

**A source image is attached `-readonly`, and the flag is derived from which side it's on — never passed by a caller.** The volume mounts `MNT_RDONLY`, so the kernel refuses every write to it: that is the restore direction's proof of [the one rule](#the-one-rule), permanent and automatic rather than a manual test someone has to remember. It's belt-and-braces too, since the resulting `Drive.isReadOnly` is true, so the *existing* "target is read-only" blocker would fire if a refactor ever put an image on the target side. Covered by two harness checks that try to write and confirm it throws.

**The image file may not live on either drive in the copy.** A blocker, not a nicety. Saving with the image on the source means writing to the source; restoring with it on the target means the mirror deletes the image *while reading from it*. Containment is checked component-wise (`ImagePreflight.volume(_:contains:)`) so `/Volumes/HOT` doesn't appear to contain `/Volumes/HOTFIRE/x.sparseimage`.

**A mounted image reports free space against its *virtual* size, so `PreflightReport`'s existing space check is meaningless for one.** It would pass cheerfully while the Mac holding the file has 2 GB left, and the copy would die part-way with ENOSPC. `ImagePreflight` checks the volume that actually holds the `.sparseimage` instead. This is the single most important new rule.

**`hdiutil -size NNNb` means SECTORS, not bytes.** Measured 2026-08-14: `-size 128000000000b` produced a **65 TB** image (128e9 × 512) whose exFAT partition silently capped at ~2 TB with the rest left as free space. `DiskImageStore.sizeArgument` converts to whole MiB (`m`) for exactly this reason, and three harness checks pin it.

**Images are sized at creation from the source's whole capacity, because a FAT filesystem cannot be grown afterwards.** `hdiutil resize` would enlarge the partition and leave the filesystem untouched — a silent no-op. A source can't hold more than its own capacity and a sparse image costs only what's written, so over-sizing is free. There is deliberately no resize path.

**Sparse images never shrink — compaction does not work on FAT.** Measured 2026-08-14: after deleting a 40 MB file from an exFAT sparse image, `hdiutil compact` reported *"Reclaimed 0 bytes out of 0 bytes possible."* hdiutil can't read FAT/exFAT free-space maps. So an image grows to the largest the library has ever been and stays there, and the free-space blocker deliberately gives no credit for deletions. Don't add a compaction step; it was tried and measured.

**Images mount at a private `-mountpoint` under Application Support with `-nobrowse`, never in `/Volumes`.** An attached image reports both `removable` and `ejectable` as true, so a `/Volumes` mount would sail through `DriveScanner`'s eligibility gate and offer itself in the picker as an ordinary backup target. Measured 2026-08-14: a `-nobrowse` image at a private mount point does not appear in `mountedVolumeURLs(options: .skipHiddenVolumes)` at all. `DriveScanner` *also* excludes `DiskImageStore.mountRoot` explicitly, and a harness check pins the invisibility.

**`FilesystemCheck` is skipped when the source is an image**, and that's a correctness fix rather than an optimisation. It confirms a volume came back by testing its *original* mount path, and macOS remounts a detached image at `/Volumes/<name>` — so `volumeRemounted` would go false and raise a hard blocker on a perfectly good image. A structurally damaged sparse image doesn't attach at all, which is the check that actually matters for a file.

**The image attachment outlives a single `defer` scope.** It spans two detached Tasks — analysis and the copy — with the preflight screen in between, so release is funnelled through `CloneJob.setPhase` on every terminal phase, plus `reset()`. `DiskImageStore.reapStaleMounts()` at launch is the backstop for the one path nothing can cover: the app being killed mid-run, which otherwise leaves a mount that makes the *same* image fail to attach later with a confusing "resource busy".

**Erasing is target-only, and the type is what says so rather than a comment.** `DriveFormatter.erase` takes an `EraseApproval` and nothing else. `EraseApproval`'s initializer is `fileprivate` to `FormatPreflight.swift`, so `FormatPreflight.approve(_:)` is the only thing in the app that can produce one, and it returns `nil` whenever `evaluate` produced a blocker. The disabled Erase button is the visible half of that; the token is the half that still holds if the button is ever mis-wired or a second caller appears. If you find yourself wanting to construct an approval somewhere else, that is the mistake this shape exists to catch.

**The erase rewrites the whole disk, with an MBR partition map.** `eraseVolume` would remake the filesystem inside the partition it found and leave the partition scheme alone — which is useless for the case that actually brings someone here, a stick that mounts perfectly on a Mac and shows nothing on a CDJ because it is GPT or has an EFI slice in front of it. MBR because Pioneer's documentation is written against MBR FAT32/exFAT and macOS reads MBR without complaint, so the conservative choice costs nothing. The consequence is that *every* partition on the physical disk goes, which is why `FormatPreflight` enumerates them and names them in a warning, and why the source's whole-disk BSD name is a blocker and not just its volume path.

**Nothing in the erase path is privileged, and that is a decision to defend.** Measured 2026-08-19: `diskutil eraseVolume` and a whole-disk `diskutil eraseDisk` both exit 0 with no authentication prompt against an attached disk image, and DiskArbitration authorizes the console user for external removable media, which is the only kind of volume `DriveScanner` ever produces. So there is no `osascript`-with-administrator-privileges path here and there must not be one added: a root shell script that erases a disk is a far worse thing for this project to own than an error message, and the honest fallback when `diskutil` refuses is the "Open Disk Utility…" button already on the sheet. Same reasoning as `DiskImageStore`, and the header of `DriveFormatter` says so where someone would go looking.

**There is no cancel on an erase.** A `dd` killed halfway leaves a target the user can still recognise as broken — `CloneJob.finishInterrupted` says exactly that. A repartition killed halfway leaves a disk with no partition map at all. The operation takes a few seconds, so the honest interface is a disabled Cancel button with a tooltip, not a race.

**FAT32's 2 TB ceiling is a blocker, checked before anything starts.** `newfs_msdos` refuses a disk larger than 2^32 sectors — but `diskutil eraseDisk` rewrites the partition map *first* and formats *second*, so hitting the limit leaves a disk with a fresh partition map and no filesystem. Catching it in `FormatPreflight` costs one comparison; not catching it costs the user their drive.

**The update's security boundary is one `codesign -R` requirement, and everything else is downstream of it.** The feed is JSON from the network, and the DMG is whatever URL that JSON named. Nothing is executed, moved, or believed to be ThumbPrint until `UpdateInstaller.verify` has confirmed the downloaded bundle satisfies `anchor apple generic and identifier "com.saschanowlin.ThumbPrint" and certificate leaf[subject.OU] = "DPLC4BD7ST"` — Apple's chain, this identifier, this team. Verified 2026-08-19 in both directions: the requirement passes against the shipped 1.0 and fails against an unrelated Apple binary. Gatekeeper (`spctl --assess`) and a version match against the feed are checked too, but they are corroboration; the requirement is the thing that makes a substituted download unusable.

**No Sparkle, and that is considered rather than lazy.** Sparkle would bring an EdDSA appcast, a second signing key to keep safe, and the project's first dependency. What it buys over ~400 lines here is delta updates and an installer XPC service, neither of which matters for a 2 MB notarized app distributed through one channel. If the app ever grows past that, revisit — but revisit with those two specific gains in mind.

**The updater refuses to replace an app running from a build folder.** `UpdateInstaller.destination` returns `.revealOnly` for any bundle path containing `/DerivedData/` or `/Build/Products/`, and for any bundle whose parent directory isn't writable. The second is practical — replacing it would need a password, and this feature is not worth a privileged helper. The first is about not doing something startling: `Scripts/build.sh` runs the app from exactly there, and silently swapping a freshly compiled debug build for the public release is a genuinely confusing thing to do to someone mid-session. Both fall back to leaving the verified DMG in ~/Downloads.

**`AppVersion` exists because string ordering puts "1.10" before "1.9".** That is a bug that only bites once and then never gets a chance to correct itself: the app would decide it was already current and stop offering the newer build forever. Component-wise numeric comparison, with a missing component read as zero so `1.0` and `1.0.0` are one version rather than two.

**The relaunch waits on the old process's PID before calling `open`.** `open` on a bundle whose previous process is still running activates *that* process rather than starting the new one — so without the wait the user watches the app they just replaced come back. Polling `kill -0` from a detached `/bin/sh` and then opening is the one form of this that needs no helper tool.

**`UpdateInstaller.install` only deletes a temp directory it recognises as its own.** The obvious spelling of the cleanup — remove the folder the DMG was in — would delete whatever directory a future caller happened to hand it a disk image from. It checks for the `thumbprint-update-` prefix under `NSTemporaryDirectory()` before removing anything. Caught while testing the install path against a DMG in `dist/`.

**The update sheet is held back while a copy is running.** `UpdateController` decides *whether* there is anything to say; `ContentView.presentingUpdate` decides *when* it may be said, and the answer is never during `analyzing` or `running`. An update prompt over a backup in flight would be the app interrupting the only job it has. The automatic check is silent in every other outcome too — offline, rate-limited, up to date, or a version the user already skipped.

---

## Testing

There's no XCTest target. The meaningful failure modes are hardware and filesystem behaviours that unit tests can't reach, so testing is done against **real filesystems on disk images**.

**`./Tests/run.sh` is the suite.** It creates two throwaway exFAT images and two APFS fixture trees inside a temp directory, compiles `Tests/main.swift` against the Foundation-only sources, runs 194 checks, and tears all of it down on exit — including on failure. Exit 0 means everything passed; new checks go in `Tests/main.swift`. It writes nothing inside the repo and touches no real drive.

As of the disk-image work the suite **does** compile and drive `FileSyncEngine` and `Verifier`, including a full save-to-image and restore-from-image round trip. That widening was deliberate: the whole risk of the feature is the boundary between the mirror and a mounted image, and that boundary is only worth anything if a copy actually crosses it. `BlockCloneEngine` and `FilesystemCheck` are still not driven by the suite.

The erase checks (§ N) go further than the rest: they run a real `diskutil eraseDisk` — the same command a USB stick would get — against a throwaway sparse image the suite made, and assert the volume comes back renamed, reformatted and empty. That is deliberate. `FormatPreflight`'s rules can be driven on paper, but "is the command spelled correctly and does the volume return" cannot, and it is the half that would strand someone with an unformatted drive.

Two caveats worth knowing. The disk-image checks use the real `DiskImageStore.mountRoot` (`~/Library/Application Support/ThumbPrint/mounts`), so `reapStaleMounts` runs against it — don't run the suite while the app has an image open, it would detach it. And a repartitioned image remounts at `/Volumes/<name>`, nowhere near the temp directory, so the cleanup in `run.sh` matches attached images on their **image path** as well as their mount point. Nothing else outside the temp directory is touched, and no image file is ever deleted.

The update checks are pure: version comparison, feed parsing, the pinned requirement's text, and the build-folder refusal. The network fetch and the bundle swap are *not* in the suite — one needs GitHub and the other needs an installed app to replace. Both were exercised from throwaway CLI harnesses on 2026-08-19 (see [Status](#status)); if either changes, that is the way to re-prove it.

The recipe below is the manual version, for testing something the suite doesn't cover yet — anything involving `BlockCloneEngine` or `FilesystemCheck`, neither of which the suite drives.

```bash
# 1. Make throwaway volumes
hdiutil create -size 200m -fs "ExFAT" -volname "TP-SRC" -quiet src.dmg
hdiutil attach src.dmg -quiet          # add -readonly for the safety test
```

```bash
# 2. Compile the engine sources into a CLI harness (they're Foundation-only —
#    no SwiftUI — so they compile standalone). Put top-level code in main.swift.
swiftc -o harness \
  ThumbPrint/Model/{Drive,CloneMode,CloneError,CloneProgress,FileIndex,PreflightReport,ComparisonReport,DriveRecord}.swift \
  ThumbPrint/Services/{FileSyncEngine,Verifier,BlockCloneEngine,SourceHealthCheck,FilesystemCheck,LibraryCheck,DriveRegistryStore}.swift \
  ThumbPrint/Views/Formatting.swift main.swift

# `DriveRegistry` is deliberately absent: it's the @MainActor @Observable
# wrapper, which is why every rule worth testing lives in DriveRegistryStore.
```

Construct `Drive` values by hand pointing at `/Volumes/TP-SRC` etc. and call `makePlan` / `execute` / `Verifier.verify` directly.

**The source-safety test, which must be re-run after any engine change:**
attach the source with `hdiutil attach src.dmg -readonly`, then run a full sync. The kernel rejects all writes to that volume, so if the sync completes and verifies, the app provably cannot be writing to the source. Pair it with a before/after snapshot (`stat -f '%N|%z|%m|%p'` plus `md5`) of every source file, with the source mounted **writable**.

Always `hdiutil detach` and delete the `.dmg` files afterwards.

---

## Signing and permissions

- **App Sandbox is off** and must stay off — raw device I/O and arbitrary volume access are incompatible with it. No Mac App Store; irrelevant for a personal tool.
- **The Xcode project stays ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`, no team) on purpose, so a fork clones and builds with no certificate and no Apple account. Release also sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` to strip the `get-task-allow` debug entitlement.
- **The shipping identity is applied by `Scripts/release.sh` alone**, never by the project: `Developer ID Application: Sascha Nowlin (DPLC4BD7ST)`, hardened runtime on, secure `--timestamp`. The script re-signs the built app explicitly rather than trusting the build-phase signature, which carries neither reliably, and notarization rejects a build missing either.
- **Both the app and the disk image are notarized and stapled**, in that order: zip the app → notarize → staple the app → build the DMG from the stapled app → notarize the DMG → staple the DMG. Stapling twice is what makes the download work on a Mac that is offline or behind a filter.
- `Info.plist` needs **`NSRemovableVolumesUsageDescription`**. Without it macOS is TCC-blocked from removable volumes and the failure presents as an *empty directory listing*, not an error. On first launch the user must click Allow.
- Exact Clone's privileged script is written to a **0700** dir inside `NSTemporaryDirectory()` with the script itself **0500**, then run via `osascript … with administrator privileges`. It runs as root — never relax those modes and never put it in a world-writable path like `/tmp`.

---

## Status

**Released publicly 2026-08-19 as 1.0.** Verified the way a stranger would see it: the repository, the release and the asset all fetch anonymously, the downloaded DMG is SHA-256 identical to the built one (`d212be6c…`), and the app inside it passes `spctl --assess` as `source=Notarized Developer ID`. `docs/screenshot.png` in the README is the real picker, captured against two throwaway 32 GB exFAT volumes carrying a synthetic rekordbox library — note that launching the app against fixtures writes sighting records into the real `drives.json`, so back that file up and restore it if you do this again.

Working and verified: drive detection (against real USB hardware), file-level mirror sync, incremental re-runs, mirror deletion, verification, cancellation and resume, preflight blockers, source health screening, notifications, icon.

**UI redesigned 2026-08-12** into the shared `DesignSystem` layer: capacity bars per drive, hover/press states, 44pt hit-area floor, monospaced-digit readouts throughout, rolling percentage via `.contentTransition(.numericText())`, phase cross-fades, and the app icon on the start screen. Presentation only — nothing in `Model/` or `Services/` was touched, so the source-safety test did not need re-running for it.

**ThumbPrint backups have loaded on real hardware, twice** — the tests that actually prove the app works, and both passed:
- 2026-08-11, 18.2 GB / 6,212 files, FAT32 source → exFAT target, loaded in a CDJ.
- 2026-08-12, full ~81 GB `HOTFIRE` → `BACKUPDJ`, FAT32 → FAT32, loaded on an **XDJ-RX3 with rekordbox cue points intact**. This run also confirmed resume: it was restarted after an earlier interrupted attempt and picked up where it left off.

**Disk image save and restore, verified 2026-08-14** by 60 harness checks over real `hdiutil` images: create/attach/detach/reap, an image absent from `mountedVolumeURLs`, a read-only attach where writing genuinely throws, a full save that verifies with 0 discrepancies, a **second save copying 0 files** (the ±2s mtime regression, now across the drive↔image boundary), orphan deletion inside the image, a restore that removes what the image doesn't have and verifies, the image file byte-identical after that restore, every `ImagePreflight` rule, and the registry's one-sided image records including a pre-image `drives.json` still decoding. **Never run against real DJ hardware, and never against a large library** — the ~81 GB `HOTFIRE` round trip onto a spare stick, loaded on a CDJ, is the honest test and it hasn't happened. The picker's image rows and file panels are also unexercised outside the running app.

**Not yet tested:** Exact Clone against real hardware — the admin prompt → unmount → `dd` path has only been tested in pieces, and a cancelled run leaves the target holding a partial partition map (see `CloneJob.finishInterrupted`, which now warns about exactly that).

**The drive registry, verified 2026-08-13** by 28 harness checks over a throwaway store file: first sighting versus repeat sighting (`firstSeen` preserved, `lastSeen` advanced, rename and capacity picked up, no duplicate record), a drive with no UUID ignored, content snapshots matching the index, both sides of a sync recorded with the right roles and counterparty names, throughput derived from duration, an unverified run recording the attempt while leaving the target's snapshot unset, an exact save/load round trip including dates, a corrupt file moved aside with the original preserved and no records loaded, and a `version: 999` file left byte-identical with saving refused. Not yet exercised: the `@Observable` `DriveRegistry` wrapper and the picker's history line, both of which need the running app rather than a harness.

**Export staleness and Compare, verified 2026-08-12** by a harness over two throwaway exFAT images plus two APFS directories — 32 checks, all passing. Covered: a stale library (one track 9 days past the export, correctly the only one flagged, with the note naming the gap and the database path), a fresh library producing no note, audio with no library at all, the three-way file diff (left-only / right-only / differing / identical) against a real ±2s FAT mtime, `ComparisonReport`'s cross-drive library-asymmetry note, and a drive compared with itself reporting identical. Neither feature has been run against real DJ hardware yet, and no comparison has been made between two *large* real libraries — the 81 GB `HOTFIRE` case would be the honest test of the list caps in `ComparisonView`.

**Erasing a backup drive, built 2026-08-19.** `DiskFormat` + `FormatPreflight` + `DriveFormatter` + `FormatDriveView`, reachable from one row at the bottom of the destination list, and only ever for the drive already chosen as the destination. Whole-disk `diskutil eraseDisk` to exFAT or FAT32 with an MBR partition map, unprivileged, with the source refused two ways. Covered by 34 harness checks: every refusal (the source volume, another partition of the source's disk, no disk device, read-only media, FAT32 over 2 TB, a selected disk image living on the drive), the component-wise containment that keeps `/Volumes/BACKUP` from looking like `/Volumes/BACKUPDJ`, the volume-label sanitizing shared with the image feature, and **a real `diskutil eraseDisk` against a throwaway sparse image** that comes back renamed, reformatted FAT32, empty and writable. Not yet run against a real USB stick, and no erased stick has been loaded in a CDJ — that is the honest test and it hasn't happened.

**Update check and apply, built 2026-08-19.** `AppVersion` + `UpdateRelease` + `UpdateInstaller` + `UpdateController` + `UpdateSheet`. A silent once-a-day check against `api.github.com/repos/elDoof/ThumbPrint/releases/latest`, a sheet only when there is genuinely something newer that hasn't been skipped, and "Check for Updates…" in the app menu for the manual case. 36 harness checks cover version comparison, feed parsing and its four refusals, asset selection, the pinned requirement's text and the build-folder refusal.

The two halves the harness can't reach were proven from throwaway CLI harnesses the same day, and this is what was actually observed:

- The live fetch returns `v1.0`, parses to one `ThumbPrint-1.0.dmg` asset of 2,411,354 bytes, and correctly reports itself as *not* newer than a 1.0 install and newer than a 0.9 one.
- The pinned requirement **accepts** the installed, notarized 1.0 and **rejects** `/System/Applications/Calculator.app` — it discriminates in both directions, which a requirement that merely always passed would not.
- The version pin refuses a bundle offered as 9.9 that contains 1.0.
- A full `install` against a scratch copy of the app, using the real notarized `dist/ThumbPrint-1.0.dmg`: the copy was replaced, a marker file planted inside it was gone afterwards, the replaced bundle still satisfied the pinned requirement, no staging directory was left behind, and the DMG's own directory was correctly *not* deleted.

What remains unproven is the one thing that needs a newer release to exist: nobody has clicked **Install and Relaunch** in the running app and watched it come back.

**Read-only-mount test:** re-run 2026-08-11 after the `autoreleasepool` fix touched `FileSyncEngine` and `FileIndex`. A full 2 GB / 1,512-file sync from a source attached with `hdiutil attach -readonly` completed and verified with 0 discrepancies, and a before/after `stat` snapshot of 3,030 user files was byte-identical. The only source-side delta was macOS's own `.fseventsd` journal, flushed by the OS at unmount — a path `FileIndex` excludes and never reads.

**Performance, so it isn't re-litigated:** a 45-minute 18.2 GB backup was traced to the *source drive*, not this code — ~23% of large files read at 1.2–3.5 MB/s (fragmentation; unchanged by a successful `fsck` repair) while the rest read at 43–75 MB/s and the target writes 46 MB/s. Measured and **disproven** as causes: the per-file `fsync` (no gain, so its crash-safety is free), pipelining reads against writes (0.80×, a regression), the tree walks (0.3 s total), and mtime stamping (~1 ms/file). The only real software win found was 3–4 concurrent file copies (1.9× on large files), deliberately deferred until a healthy source exists to baseline against.

---

## Roadmap

Ordered by value per unit of effort, and every one of them is read-only on the source — none of these is a reason to relax [the one rule](#the-one-rule).

**Export-staleness check — built 2026-08-12.** `LibraryCheck.swift`. Finds `PIONEER/rekordbox/export.pdb` / `_Serato_/database V2` (matched case-insensitively, since FAT is case-insensitive) and reports audio files whose mtime is later than the database's. Emitted as preflight *warnings*, never blockers: a stale library is a condition of the source, and refusing to copy would leave the user with neither a fixed library nor a backup.

The one soft assumption is `LibraryReport.staleTolerance` (1 hour). An export writes the database and copies audio as one operation and **which lands last was not measured**, so the tolerance exists to stop write ordering alone from tripping the check while still catching the real case — a track added days later. A false positive immediately after an export means that assumption is what to go and measure.

**Compare-only mode — built 2026-08-12.** `CloneMode.compareOnly` → `ComparisonReport` → `ComparisonView`, with the diff in `FileIndex.compare`. Unlike `SyncPlan` it keeps "missing" and "different" apart, because with nothing about to be written those are different findings. Drives are `left`/`right`, never source/target. Uses the same ±2s `modificationTolerance` as `plan`, so a byte-perfect FAT copy reads as identical rather than as a whole library of differences.

**Drive registry — built 2026-08-13.** `DriveRecord` + `DriveRegistryStore` + `DriveRegistry`, persisted to `~/Library/Application Support/ThumbPrint/drives.json` and **never to a drive**. Records name, format, capacity, first/last sighting, a `ContentSnapshot` (file count, bytes, libraries found, newest database mtime, audio count) and the last `SyncRecord` from each drive's own side. Surfaced today as one line per row in the picker — "Backed up to BACKUPDJ · 3 days ago".

Decisions worth keeping:

- **Keyed by volume UUID only.** A drive with no readable UUID is not tracked at all. DJ drives are routinely named `UNTITLED`, and inferring identity from a name is how a registry starts lying about which stick is which.
- **Split in two.** The store is a plain value type holding every rule; the `@Observable` class only adds isolation and write timing. That's what makes the schema, corruption, and recording behaviour testable without a main actor.
- **A corrupt file is moved aside, never overwritten** (`drives.json.unreadable-<timestamp>`), and a file from a *newer* schema is left strictly alone — `canSave` goes false so this build can't destroy what a later one wrote.
- **Unverified runs are recorded as attempts.** The target's `ContentSnapshot` is only set from the source's index when the run verified, because that is exactly what a verified mirror asserts. The picker says "unverified" rather than "backed up".
- **Exact Clone is deliberately not recorded.** A raw clone reproduces the source's volume identity, so the target's pre-clone UUID stops describing that drive the moment it succeeds; a record against it would be an assertion about a volume that no longer exists.
- **Registry write failures are swallowed** and only kept in `lastWriteError`. Failing to remember a drive must never interrupt, delay, or cast doubt on backing one up.
- Dates round-trip as ISO 8601, which carries **no fractional seconds**. Irrelevant for sighting times; it does mean a test asserting `Date` equality has to use whole-second values.

**Disk image save and restore — built 2026-08-14.** `Endpoint` + `DiskImageStore` + `ImagePreflight`, so a backup can be made without two sticks plugged in at once. Save a drive into a single `.sparseimage`, restore it onto a different drive later. Details under [Load-bearing details](#load-bearing-details); the short version is that a mounted image *is* a `Drive`, so no copy engine changed.

**Pre-gig readiness check** — next, and now unblocked: the registry already stores `SyncRecord.averageBytesPerSecond` per drive, which is the history half of the throughput signal. One read-only button bundling `FilesystemCheck`, free space, export staleness, and a read-throughput sample into a green/amber/red verdict. The throughput sample earns its place from measurement already in this repo: 23% of large files on a fragmented source read at 1.2–3.5 MB/s against 43–75 MB/s for the rest, which on a CDJ is a track that takes visibly long to load. Sampled per drive over time it also detects failing flash.

**Library-aware verification** (bigger, and the real differentiator). `Verifier` proves the bytes copied; it does not prove the drive will *load*. Parsing the target's library database closes that gap: rows in `export.pdb` whose file is missing (shows in the player, won't play), audio on the drive no row references (invisible on the player, often gigabytes), and a playlist diff between runs. The `.pdb` and Serato `database V2` layouts are community reverse-engineering (Deep Symmetry's crate-digger), not vendor documentation — **verify against the live `HOTFIRE` tree before building on any structural claim.** Parsing is read-only, so the one rule is unaffected.

**Erase from the preflight screen, not just the picker.** The moment someone most wants to reformat a backup drive is the moment preflight says "“BACKUPDJ” is APFS — the copy will work, but the drive may not be readable by a CDJ", and today that means going Back and finding the row. It was left out of 1.1 for a real reason rather than laziness: erasing invalidates the analysis the screen is showing, so the route has to end in `job.reset()` and a re-analysis, and wiring a destructive action into a screen whose whole job is to be the last calm moment before one deserves its own think. Cheap, but not free.

Smaller, all cheap: auto-sync prompt on plug-in (`DriveScanner` already watches mounts); N-way fan-out to 2–3 targets reading the source once; a format-mismatch note in preflight from the player-support matrix already written down above; opt-in content-hash verify with per-drive caching, which catches silent bit-rot that size+mtime cannot; and space planning that names the biggest folders instead of just blocking.

The old "explicit Restore direction" item is **half-delivered** by disk images: restoring an image onto a replacement drive works today. Drive → drive restore is still just Fast Sync with the arguments swapped, and the original point stands — a separate direction would exist to be unambiguous about which drive is now the protected source.

**Deliberately not planned: selective-sync exclude rules.** In a mirror, an excluded path has to mean "don't copy *and* don't delete." Get it backwards and the app quietly deletes tracks from a backup. Worth doing carefully some day, never worth doing casually.

Unverified Serato items, listed so they get tested rather than assumed: whether cue points live in ID3 `GEOB` frames inside the audio files (if so, a data-fork copy carries them, matching the rekordbox finding above), and whether crate files store paths in a form that a target volume rename breaks — which would justify a volume-name mismatch warning.

---

## Environment notes

- Xcode 26.6, macOS SDK 26.5, deployment target 14.0, Swift 5 language mode.
- `xcodebuild` prints a harmless `CoreSimulator is out of date` warning on every run; ignore it.
