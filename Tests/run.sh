#!/bin/bash
#
# Runs ThumbPrint's test harness.
#
# There is no XCTest target, on purpose: the failure modes that matter here are
# filesystem behaviours a unit test can't reach — FAT's 2-second mtime
# resolution, NFC vs NFD filenames, which files an enumerator will admit exist.
# So the harness compiles the Foundation-only Model/Services sources into a CLI
# binary and points it at real filesystems on throwaway disk images.
#
# Everything is created in a temp directory and destroyed on exit, including on
# failure. Nothing is written inside the repo, and no real drive is touched.
#
# Usage:  ./Tests/run.sh
# Exit:   0 if every check passed, 1 if any failed, 2 on a harness error.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TP="$ROOT/ThumbPrint"
WORK="$(mktemp -d)"

SRC_MOUNT="$WORK/src-volume"
DST_MOUNT="$WORK/dst-volume"

cleanup() {
    # Detach before deleting: pulling the directory out from under a mounted
    # image leaves a wedged entry in `mount` until reboot.
    hdiutil detach "$SRC_MOUNT" -quiet 2>/dev/null
    hdiutil detach "$DST_MOUNT" -quiet 2>/dev/null

    # The disk-image checks attach images of their own, and one deliberately
    # leaves an attachment behind to prove the reaper collects it. Anything still
    # mounted under $WORK goes now, or it outlives this run.
    hdiutil info -plist 2>/dev/null | python3 -c '
import sys, plistlib, subprocess, os
work = os.environ.get("WORK", "")
try:
    data = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
for image in data.get("images", []):
    path = image.get("image-path", "")
    # Matched on the image path as well as the mount point: the erase check
    # repartitions a throwaway image, and the volume that comes back is mounted
    # at /Volumes/<name>, nowhere near $WORK.
    owned = bool(work) and path.startswith(work)
    for entity in image.get("system-entities", []):
        point = entity.get("mount-point", "")
        if owned or (work and point.startswith(work)):
            subprocess.run(["hdiutil", "detach", entity.get("dev-entry", point),
                            "-force", "-quiet"], check=False)
' 2>/dev/null

    rm -rf "$WORK"
}
export WORK
trap cleanup EXIT

: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

echo "==> Creating exFAT test volumes"
# Mounted at an explicit mountpoint rather than /Volumes: a stale TP-SRC would
# otherwise mount as "TP-SRC 1" and the fixtures would land somewhere else.
hdiutil create -size 200m -fs "ExFAT" -volname "TP-SRC" -quiet -ov "$WORK/src.dmg" || exit 2
hdiutil create -size 200m -fs "ExFAT" -volname "TP-DST" -quiet -ov "$WORK/dst.dmg" || exit 2
mkdir -p "$SRC_MOUNT" "$DST_MOUNT"
hdiutil attach "$WORK/src.dmg" -mountpoint "$SRC_MOUNT" -nobrowse -quiet || exit 2
hdiutil attach "$WORK/dst.dmg" -mountpoint "$DST_MOUNT" -nobrowse -quiet || exit 2

echo "==> Writing fixtures"
S="$SRC_MOUNT"
D="$DST_MOUNT"

mkdir -p "$S/PIONEER/rekordbox" "$S/Contents" "$D/Contents"
printf 'pdb'     > "$S/PIONEER/rekordbox/export.pdb"
printf 'old'     > "$S/Contents/Old Track.mp3"
printf 'new'     > "$S/Contents/New Track.mp3"
printf 'sidecar' > "$S/Contents/._New Track.mp3"
printf 'aaaa'    > "$S/Contents/Shared.mp3"

printf 'old' > "$D/Contents/Old Track.mp3"
printf 'bb'  > "$D/Contents/Shared.mp3"
printf 'x'   > "$D/Contents/Extra.mp3"

# The export is dated 2026-08-01 12:00. One track lands 9 days later, which is
# the staleness the check must find; everything else predates the export.
# Whole minutes only — exFAT stores mtimes at 2-second resolution.
touch -t 202608011200 "$S/PIONEER/rekordbox/export.pdb"
touch -t 202608011100 "$S/Contents/Old Track.mp3" "$S/Contents/Shared.mp3"
touch -t 202608101200 "$S/Contents/New Track.mp3" "$S/Contents/._New Track.mp3"
touch -t 202608011100 "$D/Contents/Old Track.mp3" "$D/Contents/Shared.mp3" "$D/Contents/Extra.mp3"

# APFS directories for the cases that are about logic rather than filesystem
# behaviour: a library newer than its audio, and audio with no library at all.
mkdir -p "$WORK/fresh/PIONEER/rekordbox" "$WORK/fresh/Contents" "$WORK/nolib/Contents"
printf 'pdb' > "$WORK/fresh/PIONEER/rekordbox/export.pdb"
printf 'trk' > "$WORK/fresh/Contents/track.mp3"
touch -t 202608011100 "$WORK/fresh/Contents/track.mp3"
touch -t 202608111200 "$WORK/fresh/PIONEER/rekordbox/export.pdb"
printf 'trk'  > "$WORK/nolib/Contents/track.mp3"
printf 'side' > "$WORK/nolib/Contents/._track.mp3"

echo "==> Compiling harness"
# Only the Foundation-only sources. Anything touching SwiftUI can't be compiled
# standalone, which is part of why the engines don't import it.
#
# `FileSyncEngine` and `Verifier` are compiled in as of the disk-image work.
# That is a deliberate widening: the whole risk of saving to an image is the
# boundary between the mirror and a mounted image, and that boundary is only
# worth anything if the suite actually drives a copy across it.
#
# `DriveFormatter` and `UpdateInstaller` are in for the same reason: the erase
# checks drive a real `diskutil eraseDisk` against a throwaway image, and the
# update checks pin the pinned-signature requirement and the feed parsing. The
# network half of `UpdateInstaller` is compiled but never called.
#
# `DriveRegistry`, `DriveScanner` and `UpdateController` stay out — they're the
# @MainActor @Observable wrappers, which is why every rule worth testing lives in
# a value type instead.
swiftc -o "$WORK/harness" \
    "$TP"/Model/{Drive,CloneMode,CloneError,CloneProgress,FileIndex,ComparisonReport,DriveRecord,Endpoint,ImagePreflight}.swift \
    "$TP"/Model/{DiskFormat,FormatPreflight,AppVersion,UpdateRelease}.swift \
    "$TP"/Services/{LibraryCheck,DriveRegistryStore,DiskImageStore,FileSyncEngine,Verifier}.swift \
    "$TP"/Services/{DriveFormatter,UpdateInstaller}.swift \
    "$TP"/Views/Formatting.swift \
    "$ROOT/Tests/main.swift" || exit 2

mkdir -p "$WORK/images"

echo "==> Running"
"$WORK/harness" "$S" "$D" "$WORK/fresh" "$WORK/nolib" "$WORK/registry" "$WORK/images"
