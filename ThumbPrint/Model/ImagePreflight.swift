import Foundation

/// The image-specific half of preflight.
///
/// Kept apart from `PreflightReport` for one reason: `PreflightReport` isn't in
/// `Tests/run.sh`'s compile list, so nothing in it is covered. These are the
/// safety-critical rules of the whole feature — one of them is a direct guard on
/// the one rule — so they live in a pure value type that the harness can drive
/// without a mounted volume or a subprocess.
///
/// Every function here is a pure function of facts already gathered elsewhere.
struct ImagePreflight {

    /// Which side the image sits on. Named for what the user is doing rather than
    /// for source/target, because that's the thing it's easy to get backwards.
    enum Direction: Equatable {
        /// Drive → image. The image is the target.
        case save
        /// Image → drive. The image is the source, attached read-only.
        case restore
    }

    /// A mounted volume involved in this job, for the containment rule.
    struct VolumeRef: Equatable {
        var name: String
        var path: String

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    struct Facts: Equatable {
        var direction: Direction
        var imageURL: URL
        var imageDisplayName: String

        /// The volume the `.sparseimage` FILE lives on — not the volume inside it.
        ///
        /// A mounted sparse image reports free space against its *virtual* size, so
        /// `PreflightReport`'s existing space check is meaningless here: it would
        /// happily pass while the Mac holding the file has 2 GB left. This is the
        /// only figure that says whether the copy can actually land.
        var hostFormatDescription: String
        var hostAvailableCapacity: Int64

        var bytesToCopy: Int64

        /// Volume roots of both endpoints. The image file must not be inside either.
        var endpointVolumes: [VolumeRef]

        var imageFormatDescription: String
        var driveFormatDescription: String
        var driveName: String
    }

    /// Free space the copy needs beyond its own bytes, for image metadata and the
    /// filesystem's own overhead.
    static let spaceHeadroom: Int64 = 64 * 1024 * 1024

    // MARK: - Rules

    static func evaluate(_ facts: Facts) -> (blockers: [String], warnings: [String]) {
        var blockers: [String] = []
        var warnings: [String] = []

        // 1. The image file must not live on either drive in the copy.
        //
        // This is a guard on the one rule, not a convenience check. On a save, the
        // image sitting on the source means ThumbPrint would be writing to the
        // source. On a restore it's worse: the image is on the target, so the
        // mirror deletes the very file it is reading from, part-way through.
        if let containing = facts.endpointVolumes.first(where: { volume($0.path, contains: facts.imageURL) }) {
            switch facts.direction {
            case .save:
                blockers.append(
                    "The disk image “\(facts.imageDisplayName)” is on “\(containing.name)”, one of the drives in this copy. Saving to it would mean writing to a drive ThumbPrint is reading. Choose a location on your Mac or another drive."
                )
            case .restore:
                blockers.append(
                    "The disk image “\(facts.imageDisplayName)” is on “\(containing.name)”, the drive being restored. Restoring would delete the image while reading from it. Move the image somewhere else first."
                )
            }
        }

        // 2. A FAT host can't hold the file.
        //
        // Flat refusal rather than arithmetic on the projected size: FAT32 caps a
        // single file at 4 GB, and a write that dies at exactly that point is the
        // silent-truncation class this project refuses to ship. There is no good
        // reason to keep a DJ drive image on a FAT volume. exFAT hosts are fine.
        if isFATFamily(facts.hostFormatDescription), !isExFAT(facts.hostFormatDescription) {
            blockers.append(
                "The disk image is on a FAT32 volume, which can't hold a file larger than 4 GB. The image would fail as soon as it grew past that. Choose a location on your Mac or an exFAT drive."
            )
        }

        // 3. Room on the volume actually holding the file.
        //
        // Deliberately pessimistic: bytes freed by deletions inside the image are
        // not credited, because hdiutil cannot reclaim free space from a FAT
        // filesystem — a sparse image only ever grows. Measured 2026-08-14:
        // `hdiutil compact` reports "Reclaimed 0 bytes out of 0 bytes possible".
        if facts.direction == .save, facts.bytesToCopy > 0 {
            let needed = facts.bytesToCopy + spaceHeadroom
            if needed > facts.hostAvailableCapacity {
                blockers.append(
                    "Not enough room where the disk image is stored. Needs \(ByteFormat.string(needed)), has \(ByteFormat.string(facts.hostAvailableCapacity))."
                )
            }
        }

        // 4. Format mismatch between the image's insides and the drive.
        //
        // Only worth saying when the two genuinely differ; on a fresh image the
        // format is copied from the drive, so this fires for an existing image
        // being reused for a differently-formatted drive.
        if !facts.imageFormatDescription.isEmpty,
           !facts.driveFormatDescription.isEmpty,
           facts.imageFormatDescription != facts.driveFormatDescription {
            warnings.append(
                "The disk image is \(facts.imageFormatDescription); “\(facts.driveName)” is \(facts.driveFormatDescription). The files copy either way, but the two won't match byte-for-byte in format."
            )
        }

        // 5. A restore does not rename the drive.
        if facts.direction == .restore {
            warnings.append(
                "Restoring copies files onto “\(facts.driveName)” but doesn't rename it. Rekordbox stores paths relative to the drive root, so it's unaffected; whether Serato crates reference the volume name is untested."
            )
        }

        return (blockers, warnings)
    }

    // MARK: - Selection-time refusal

    /// The subset that can be decided the moment a file is picked, before anything
    /// is created or attached.
    ///
    /// These can't be preflight blockers: a `PreflightReport` needs two live
    /// `Drive`s, and these are exactly the cases where attaching never happened.
    /// Returning a message here lets the picker refuse the selection outright
    /// rather than failing mid-analysis. Don't "fix" this by moving it.
    static func selectionRefusal(
        imageURL: URL,
        hostFormatDescription: String,
        mountedVolumes: [VolumeRef]
    ) -> String? {
        if let containing = mountedVolumes.first(where: { volume($0.path, contains: imageURL) }) {
            return "That location is on “\(containing.name)”. Keep the disk image somewhere other than the drives you're copying — on your Mac, or on a different drive."
        }

        if isFATFamily(hostFormatDescription), !isExFAT(hostFormatDescription) {
            return "That location is a FAT32 volume, which can't hold a file larger than 4 GB. Choose your Mac or an exFAT drive instead."
        }

        return nil
    }

    // MARK: - Helpers

    /// Component-wise containment, so `/Volumes/HOT` does not appear to contain
    /// `/Volumes/HOTFIRE/backup.sparseimage`. A plain `hasPrefix` gets this wrong,
    /// and getting it wrong here means either a false blocker or a missed one.
    static func volume(_ volumePath: String, contains fileURL: URL) -> Bool {
        let volumeComponents = URL(fileURLWithPath: volumePath)
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComponents = fileURL
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents

        // "/" contains everything, but the boot volume is never an endpoint, so
        // this only comes up in tests.
        guard volumeComponents.count <= fileComponents.count else { return false }
        return Array(fileComponents.prefix(volumeComponents.count)) == volumeComponents
    }

    static func isFATFamily(_ formatDescription: String) -> Bool {
        formatDescription.lowercased().contains("fat")
    }

    static func isExFAT(_ formatDescription: String) -> Bool {
        formatDescription.lowercased().contains("exfat")
    }
}
