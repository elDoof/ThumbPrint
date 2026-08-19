import Foundation

/// Creates, mounts and releases the `.sparseimage` files ThumbPrint saves a drive
/// into.
///
/// Everything here is a thin wrapper over `hdiutil`, and **none of it is
/// privileged**. The image is a file the user owns, mounted into a directory the
/// user owns, brokered by the per-user `diskimages-helper`. So this path never
/// touches the `osascript`/admin-prompt machinery in `BlockCloneEngine` — no
/// helper script, no 0700 workspace, no root. Don't copy that machinery here.
///
/// A namespace of statics with no stored state, like `FilesystemCheck` and
/// `Verifier`, so `Tests/run.sh` can compile it and drive real `hdiutil` against
/// real images. The boundary between the mirror and a mounted image is where this
/// feature's risk lives, and it is only worth anything if it's testable.
enum DiskImageStore {

    // MARK: - Types

    struct Attachment: Equatable {
        /// Whole-disk node, e.g. `/dev/disk7`. Detaching by the device rather than
        /// the mount point still works if the volume got unmounted underneath us.
        let devEntry: String
        let mountPoint: URL
        let imageURL: URL
        let isReadOnly: Bool
    }

    struct ImageInfo: Equatable {
        /// `"SPRS"` for a sparse image — what `hdiutil create -type SPARSE` makes.
        var format: String
        /// Bytes the volume *inside* presents. Not what the file costs.
        var virtualSize: Int64
        /// Bytes the `.sparseimage` file occupies right now.
        var fileSize: Int64

        var isSparse: Bool { format == "SPRS" || format == "UDSB" || format == "UDSP" }
    }

    struct AttachedImage: Equatable {
        let imageURL: URL
        let devEntry: String
        let mountPoint: URL?
    }

    enum Failure: LocalizedError, Equatable {
        case createFailed(String)
        case attachFailed(String)
        case notADiskImage(String)
        case alreadyAttached(String)
        case noMountableVolume(String)
        case unsupportedFormat(String)
        case cannotReadMount(String)

        var errorDescription: String? {
            switch self {
            case .createFailed(let detail):
                return "Couldn't create the disk image.\n\n\(detail)"
            case .attachFailed(let detail):
                return "Couldn't open the disk image.\n\n\(detail)"
            case .notADiskImage(let name):
                return "“\(name)” isn't a disk image ThumbPrint can read."
            case .alreadyAttached(let name):
                return "“\(name)” is already open. Eject it in Finder, then try again."
            case .noMountableVolume(let name):
                return "“\(name)” opened but contains no volume ThumbPrint can read. It may be damaged."
            case .unsupportedFormat(let format):
                return "A disk image can only be made of an exFAT or FAT32 drive. This drive is \(format)."
            case .cannotReadMount(let path):
                return "Couldn't read the disk image after opening it at \(path)."
            }
        }
    }

    // MARK: - Locations

    /// Where images get mounted: `~/Library/Application Support/ThumbPrint/mounts`.
    ///
    /// A fixed constant, never derived from a `Drive`. That is precisely what makes
    /// it impossible to mount an image *onto* the drive being copied.
    ///
    /// Deliberately not `/Volumes`: mounting there would make the image visible to
    /// `FileManager.mountedVolumeURLs`, and `DriveScanner`'s eligibility gate is
    /// `removable || ejectable` — both of which an attached image reports as true.
    /// It would show up in the picker as an ordinary drive. Measured 2026-08-14: a
    /// `-nobrowse` image mounted under this root does not appear in
    /// `mountedVolumeURLs(options: .skipHiddenVolumes)` at all.
    static var mountRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("ThumbPrint", isDirectory: true)
            .appendingPathComponent("mounts", isDirectory: true)
    }

    /// `hdiutil -mountpoint` needs a directory that exists.
    static func makeMountPoint() throws -> URL {
        let point = mountRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: point,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return point
    }

    // MARK: - Filesystem choice, sizing, naming

    /// `hdiutil`'s spelling of the filesystem to put inside a new image, matching
    /// the drive being saved. `nil` for anything outside the FAT family — an image
    /// is only offered for a format a DJ player can actually read, and matching the
    /// source's format is this project's standing default.
    static func filesystemArgument(matching formatDescription: String) -> String? {
        let f = formatDescription.lowercased()
        // exFAT first: "exfat" also contains "fat".
        if f.contains("exfat") { return "ExFAT" }
        if f.contains("fat") { return "MS-DOS FAT32" }
        return nil
    }

    /// Sized from the source's *whole capacity* plus headroom, not its used bytes.
    ///
    /// This is what lets the image never need resizing, which matters because
    /// **macOS cannot grow an exFAT or FAT32 filesystem in place** — `hdiutil
    /// resize` would enlarge the partition and leave the filesystem untouched, a
    /// silent no-op. A source cannot hold more than its own capacity, and a sparse
    /// image costs only the bytes actually written, so over-sizing is free.
    static func recommendedSize(for drive: Drive) -> Int64 {
        let floor: Int64 = 64 * 1024 * 1024
        let headroom = max(floor, drive.totalCapacity / 50)
        return max(floor, drive.totalCapacity + headroom)
    }

    /// `hdiutil -size` in whole mebibytes.
    ///
    /// Measured 2026-08-14, and the reason this helper exists: the `b` suffix means
    /// *sectors*, not bytes. `-size 128000000000b` produces a 65 TB image
    /// (128e9 × 512), whose FAT partition then silently caps at ~2 TB with the rest
    /// left as free space. `m` is unambiguously MiB.
    static func sizeArgument(bytes: Int64) -> String {
        let mib = (max(1, bytes) + 1_048_575) / 1_048_576
        return "\(mib)m"
    }

    /// FAT32 volume labels are 11 characters from a restricted set; exFAT allows 15.
    /// Matched to the source's name as closely as the filesystem permits, because
    /// Serato crates may store the volume name in their paths — listed as unverified
    /// in docs/DEVELOPMENT.md, so the cheap thing is to preserve it rather than find out.
    static func sanitizedVolumeName(from name: String, filesystem: String) -> String {
        let limit = filesystem == "ExFAT" ? 15 : 11
        let illegal = CharacterSet(charactersIn: "*?.,;:/\\|+=<>[]\"")
        let cleaned = name.uppercased().unicodeScalars
            .filter { !illegal.contains($0) && $0.value >= 32 && $0.value < 127 }
            .map(Character.init)
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "THUMBPRINT" }
        return String(trimmed.prefix(limit))
    }

    // MARK: - Lifecycle

    /// `hdiutil create -type SPARSE …`
    ///
    /// Never passes `-ov`. An image the user picked that already exists is one to
    /// update incrementally, not one to destroy.
    ///
    /// Returns the URL that was actually written: `hdiutil` appends `.sparseimage`
    /// when the path lacks the extension, so callers must use what comes back.
    @discardableResult
    static func create(
        at url: URL,
        sizeBytes: Int64,
        filesystem: String,
        volumeName: String
    ) throws -> URL {
        let result = run("/usr/bin/hdiutil", [
            "create",
            "-type", "SPARSE",
            "-fs", filesystem,
            "-size", sizeArgument(bytes: sizeBytes),
            "-volname", sanitizedVolumeName(from: volumeName, filesystem: filesystem),
            "-quiet",
            url.path,
        ])

        guard result.status == 0 else {
            throw Failure.createFailed(result.errorText)
        }

        if FileManager.default.fileExists(atPath: url.path) { return url }
        let withExtension = url.appendingPathExtension(Endpoint.imageFileExtension)
        if FileManager.default.fileExists(atPath: withExtension.path) { return withExtension }
        throw Failure.createFailed("hdiutil reported success but no image file appeared.")
    }

    /// `hdiutil attach … -nobrowse -noautoopen -plist [-readonly]`
    ///
    /// `readOnly` is **kernel-enforced**: the volume mounts `MNT_RDONLY`, so no code
    /// path in this app or any other can write to it. That is the restore
    /// direction's proof of the one rule, which is why callers must never choose
    /// this value freely — it is derived from which side the image sits on.
    static func attach(_ imageURL: URL, readOnly: Bool, mountPoint: URL) throws -> Attachment {
        var arguments = [
            "attach", imageURL.path,
            "-mountpoint", mountPoint.path,
            "-nobrowse",
            "-noautoopen",
            "-plist",
        ]
        if readOnly { arguments.append("-readonly") }

        let result = run("/usr/bin/hdiutil", arguments)
        guard result.status == 0 else {
            let text = result.errorText
            if text.localizedCaseInsensitiveContains("resource busy")
                || text.localizedCaseInsensitiveContains("resource temporarily unavailable") {
                throw Failure.alreadyAttached(imageURL.lastPathComponent)
            }
            if text.localizedCaseInsensitiveContains("not recognized")
                || text.localizedCaseInsensitiveContains("no such file") {
                throw Failure.notADiskImage(imageURL.lastPathComponent)
            }
            throw Failure.attachFailed(text)
        }

        let entities = systemEntities(fromPlist: result.output)

        guard let mounted = entities.first(where: { $0["mount-point"] != nil }),
              let mountedPath = mounted["mount-point"] as? String
        else {
            // Opened but nothing mountable came back — release it rather than
            // leaking an attachment nobody holds a handle to.
            _ = run("/usr/bin/hdiutil", ["detach", imageURL.path, "-force", "-quiet"])
            throw Failure.noMountableVolume(imageURL.lastPathComponent)
        }

        // Shortest dev-entry is the whole disk (`/dev/disk7`) rather than a slice
        // (`/dev/disk7s1`); detaching the whole disk is the reliable form.
        let devEntry = entities
            .compactMap { $0["dev-entry"] as? String }
            .min(by: { $0.count < $1.count }) ?? imageURL.path

        return Attachment(
            devEntry: devEntry,
            mountPoint: URL(fileURLWithPath: mountedPath),
            imageURL: imageURL,
            isReadOnly: readOnly
        )
    }

    /// Releases an attachment, retrying a busy detach before forcing.
    ///
    /// Returns `false` rather than throwing when even a forced detach fails. A
    /// backup that copied and verified must not be reported as a failure because a
    /// mount point wouldn't let go — the same reasoning that makes the registry
    /// swallow its own write errors. Anything left behind is reaped at next launch.
    @discardableResult
    static func detach(_ attachment: Attachment, attempts: Int = 3) -> Bool {
        var released = false

        for attempt in 0..<max(1, attempts) {
            let result = run("/usr/bin/hdiutil", ["detach", attachment.devEntry, "-quiet"])
            if result.status == 0 { released = true; break }

            // Already gone counts as released.
            if result.errorText.localizedCaseInsensitiveContains("no such") { released = true; break }

            if attempt == attempts - 1 {
                let forced = run("/usr/bin/hdiutil", ["detach", attachment.devEntry, "-force", "-quiet"])
                released = forced.status == 0
            } else {
                Thread.sleep(forTimeInterval: 0.4)
            }
        }

        if released, attachment.mountPoint.path.hasPrefix(mountRoot.path) {
            try? FileManager.default.removeItem(at: attachment.mountPoint)
        }
        return released
    }

    /// Builds the `Drive` for a mounted image.
    ///
    /// `wholeDiskBSDName` is deliberately `nil`, which makes `supportsExactClone`
    /// false: an image is a file-level destination, and a raw `dd` onto one is not
    /// something this app offers.
    static func drive(for attachment: Attachment) throws -> Drive {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeUUIDStringKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsReadOnlyKey,
        ]

        guard let values = try? attachment.mountPoint.resourceValues(forKeys: keys) else {
            throw Failure.cannotReadMount(attachment.mountPoint.path)
        }

        return Drive(
            volumeURL: attachment.mountPoint,
            name: values.volumeName ?? attachment.imageURL.deletingPathExtension().lastPathComponent,
            wholeDiskBSDName: nil,
            totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
            availableCapacity: Int64(values.volumeAvailableCapacity ?? 0),
            volumeUUID: values.volumeUUIDString,
            formatDescription: values.volumeLocalizedFormatDescription ?? "Unknown",
            isReadOnly: values.volumeIsReadOnly ?? attachment.isReadOnly
        )
    }

    // MARK: - Inspection

    /// `hdiutil imageinfo -plist`. Throws `.notADiskImage` for a file hdiutil
    /// won't open, which is how a mistyped or corrupted selection is caught before
    /// anything is attached.
    static func info(for imageURL: URL) throws -> ImageInfo {
        let result = run("/usr/bin/hdiutil", ["imageinfo", imageURL.path, "-plist"])
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                  from: result.output, options: [], format: nil
              ) as? [String: Any]
        else {
            throw Failure.notADiskImage(imageURL.lastPathComponent)
        }

        let sizes = plist["Size Information"] as? [String: Any] ?? [:]
        let virtualSize = (sizes["Total Bytes"] as? NSNumber)?.int64Value ?? 0

        var fileSize: Int64 = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: imageURL.path),
           let size = attributes[.size] as? NSNumber {
            fileSize = size.int64Value
        }

        return ImageInfo(
            format: plist["Format"] as? String ?? "",
            virtualSize: virtualSize,
            fileSize: fileSize
        )
    }

    /// Every disk image currently attached on this machine, ours or the user's.
    static func attachedImages() -> [AttachedImage] {
        let result = run("/usr/bin/hdiutil", ["info", "-plist"])
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                  from: result.output, options: [], format: nil
              ) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return [] }

        return images.compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let devEntry = entities
                .compactMap { $0["dev-entry"] as? String }
                .min(by: { $0.count < $1.count }) ?? ""
            let mountPoint = entities
                .compactMap { $0["mount-point"] as? String }
                .first
                .map { URL(fileURLWithPath: $0) }

            return AttachedImage(
                imageURL: URL(fileURLWithPath: path),
                devEntry: devEntry,
                mountPoint: mountPoint
            )
        }
    }

    /// Whether this specific image is already open, so the picker can say so at
    /// selection time rather than failing mid-analysis.
    static func attachment(for imageURL: URL) -> AttachedImage? {
        let wanted = imageURL.resolvingSymlinksInPath().standardizedFileURL.path
        return attachedImages().first {
            $0.imageURL.resolvingSymlinksInPath().standardizedFileURL.path == wanted
        }
    }

    // MARK: - Maintenance

    /// Detaches anything still mounted under `mountRoot` and removes the leftover
    /// directories, returning how many were released.
    ///
    /// The backstop for the one failure `defer` can't cover: the app being killed
    /// while an image is attached. The mount survives the process, invisible in
    /// Finder, and would make the *same* image fail to attach next time with a
    /// confusing "resource busy". Called once at launch.
    @discardableResult
    static func reapStaleMounts() -> Int {
        let root = mountRoot.path
        var reaped = 0

        for image in attachedImages() {
            guard let mountPoint = image.mountPoint, mountPoint.path.hasPrefix(root) else { continue }
            let attachment = Attachment(
                devEntry: image.devEntry,
                mountPoint: mountPoint,
                imageURL: image.imageURL,
                isReadOnly: false
            )
            if detach(attachment) { reaped += 1 }
        }

        // Empty directories left by a previous run.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: mountRoot, includingPropertiesForKeys: nil
        )) ?? []
        for directory in contents {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if entries.isEmpty { try? FileManager.default.removeItem(at: directory) }
        }

        return reaped
    }

    // MARK: - Subprocess

    private struct CommandResult {
        let status: Int32
        let output: Data
        let errorText: String
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: Data(), errorText: error.localizedDescription)
        }

        // Read before waiting: a full pipe buffer would otherwise deadlock.
        let output = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            output: output,
            errorText: String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private static func systemEntities(fromPlist data: Data) -> [[String: Any]] {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return [] }
        return plist["system-entities"] as? [[String: Any]] ?? []
    }
}
