import Foundation

/// Erases a backup drive and lays down a fresh exFAT or FAT32 filesystem on it.
///
/// **This is the only code in ThumbPrint that destroys data it wasn't asked to
/// copy.** It is reachable exactly one way: with an `EraseApproval`, which only
/// `FormatPreflight.approve(_:)` can mint and only when no blocker applies. The
/// signature is the enforcement — there is no unchecked entry point to add a
/// caller to by mistake.
///
/// **Nothing here is privileged, and it must stay that way.** `diskutil` erases
/// external removable media for the console user without authentication —
/// measured 2026-08-19 against an attached disk image, both `eraseVolume` and a
/// whole-disk `eraseDisk`, exit 0 with no prompt. ThumbPrint only ever sees
/// removable/ejectable volumes (`DriveScanner.drive(for:)`), so that is the only
/// case this can reach. Do **not** reach for the `osascript`/admin-prompt
/// machinery in `BlockCloneEngine` to "fix" a failure here: a root shell script
/// that erases a disk is a much worse thing to own than an error message, and
/// the honest fallback is Disk Utility. Same reasoning as `DiskImageStore`.
///
/// A namespace of statics with no stored state, like `DiskImageStore` and
/// `FilesystemCheck`, so `Tests/run.sh` can compile it and drive a real erase
/// against a real disk image.
enum DriveFormatter {

    // MARK: - Types

    enum Failure: LocalizedError, Equatable {
        case notPermitted(String)
        case diskBusy(String)
        case eraseFailed(String)
        case volumeDidNotReturn(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted(let name):
                return "macOS wouldn't let ThumbPrint erase “\(name)”. Erase it in Disk Utility instead."
            case .diskBusy(let name):
                return "“\(name)” is in use and couldn't be unmounted. Close any Finder windows or apps using it, then try again."
            case .eraseFailed(let detail):
                let text = detail.isEmpty ? "" : "\n\n\(detail)"
                return "The erase didn't finish.\(text)"
            case .volumeDidNotReturn(let name):
                return "“\(name)” was erased but didn't come back. Unplug it and plug it in again — the drive should be there, freshly formatted."
            }
        }
    }

    /// Lines `diskutil` prints as it works, forwarded so the sheet can say what
    /// is happening instead of spinning silently.
    typealias StepHandler = (String) -> Void

    // MARK: - Inspection

    /// Size of the physical disk, which is what the FAT32 ceiling applies to.
    ///
    /// Deliberately its own implementation rather than a call into
    /// `BlockCloneEngine.wholeDiskSize`: that type isn't in the harness compile
    /// list (it drives `osascript`), and this one has to be.
    static func wholeDiskSize(bsdName: String) -> Int64 {
        guard let plist = plist(from: run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(bsdName)"])) else {
            return 0
        }
        if let total = plist["TotalSize"] as? NSNumber { return total.int64Value }
        if let size = plist["Size"] as? NSNumber { return size.int64Value }
        return 0
    }

    /// Every partition on the physical disk, so the confirmation can name what
    /// else is about to be destroyed.
    ///
    /// Returns an empty list when `diskutil` can't be read. That's deliberately
    /// silent: the list only feeds a warning, and a failure to enumerate must
    /// never become a reason the erase can't proceed.
    static func partitions(onWholeDisk bsdName: String) -> [FormatPreflight.SiblingVolume] {
        guard let plist = plist(from: run("/usr/sbin/diskutil", ["list", "-plist", "/dev/\(bsdName)"])),
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        return disks
            .filter { ($0["DeviceIdentifier"] as? String) == bsdName }
            .flatMap { ($0["Partitions"] as? [[String: Any]]) ?? [] }
            .compactMap { partition in
                guard let identifier = partition["DeviceIdentifier"] as? String else { return nil }
                let info = volumeInfo(deviceIdentifier: identifier)
                return FormatPreflight.SiblingVolume(
                    deviceIdentifier: identifier,
                    volumeName: (partition["VolumeName"] as? String) ?? info.volumeName,
                    content: (partition["Content"] as? String) ?? "",
                    size: (partition["Size"] as? NSNumber)?.int64Value ?? 0,
                    isMounted: info.mountPoint != nil
                )
            }
    }

    // MARK: - Erasing

    /// `diskutil eraseDisk <filesystem> <name> MBR /dev/diskN`, then waits for the
    /// volume to come back and returns it as a `Drive`.
    ///
    /// The whole disk, not the volume: the partition scheme is the thing that is
    /// usually wrong with a stick a CDJ won't read, and `eraseVolume` leaves it
    /// exactly as it found it. `MBR` for the reason recorded on
    /// `DiskFormat.partitionScheme`.
    ///
    /// **There is no cancel.** A `dd` killed halfway leaves a mess the user can
    /// still recognise; a repartition killed halfway leaves a disk with no
    /// partition map. The operation takes a few seconds — the honest interface
    /// is to let it finish.
    @discardableResult
    static func erase(_ approval: EraseApproval, onStep: StepHandler? = nil) throws -> Drive {
        let result = runStreaming(
            "/usr/sbin/diskutil",
            [
                "eraseDisk",
                approval.format.diskutilName,
                approval.volumeName,
                DiskFormat.partitionScheme,
                approval.deviceNode,
            ],
            onLine: onStep
        )

        guard result.status == 0 else {
            let text = (result.errorText + "\n" + result.outputText)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if text.localizedCaseInsensitiveContains("permission denied")
                || text.localizedCaseInsensitiveContains("not permitted")
                || text.localizedCaseInsensitiveContains("must be root")
                || text.localizedCaseInsensitiveContains("authenticat") {
                throw Failure.notPermitted(approval.driveName)
            }

            if text.localizedCaseInsensitiveContains("busy")
                || text.localizedCaseInsensitiveContains("couldn't unmount")
                || text.localizedCaseInsensitiveContains("could not unmount") {
                throw Failure.diskBusy(approval.driveName)
            }

            throw Failure.eraseFailed(lastMeaningfulLines(text))
        }

        guard let drive = mountedVolume(onWholeDisk: approval.wholeDiskBSDName, waitingUpTo: 20) else {
            throw Failure.volumeDidNotReturn(approval.volumeName)
        }
        return drive
    }

    /// Polls for the freshly created volume to mount.
    ///
    /// `diskutil` prints "Mounting disk" and exits before the mount is
    /// necessarily visible through `URL` resource values, and the new volume
    /// isn't at the old path — it's wherever macOS mounted it, which may be
    /// `/Volumes/NAME 1` if something else already holds the name. So the disk is
    /// asked rather than the path guessed.
    static func mountedVolume(onWholeDisk bsdName: String, waitingUpTo seconds: Int) -> Drive? {
        for attempt in 0...max(0, seconds * 2) {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }

            for partition in partitions(onWholeDisk: bsdName) {
                let info = volumeInfo(deviceIdentifier: partition.deviceIdentifier)
                guard let mountPoint = info.mountPoint, !mountPoint.isEmpty else { continue }
                if let drive = drive(atMountPoint: mountPoint, wholeDiskBSDName: bsdName) {
                    return drive
                }
            }
        }
        return nil
    }

    /// Reads the same resource values `DriveScanner` does, minus the eligibility
    /// gate — the drive already passed that gate before it could be selected, and
    /// erasing it doesn't change what kind of device it is.
    static func drive(atMountPoint path: String, wholeDiskBSDName: String) -> Drive? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeUUIDStringKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsReadOnlyKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        return Drive(
            volumeURL: url,
            name: values.volumeName ?? url.lastPathComponent,
            wholeDiskBSDName: wholeDiskBSDName,
            totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
            availableCapacity: Int64(values.volumeAvailableCapacity ?? 0),
            volumeUUID: values.volumeUUIDString,
            formatDescription: values.volumeLocalizedFormatDescription ?? "Unknown",
            isReadOnly: values.volumeIsReadOnly ?? false
        )
    }

    // MARK: - diskutil plumbing

    private struct VolumeInfo {
        var mountPoint: String?
        var volumeName: String?
    }

    private static func volumeInfo(deviceIdentifier: String) -> VolumeInfo {
        guard let plist = plist(from: run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(deviceIdentifier)"]))
        else { return VolumeInfo() }

        let mountPoint = plist["MountPoint"] as? String
        return VolumeInfo(
            mountPoint: (mountPoint?.isEmpty ?? true) ? nil : mountPoint,
            volumeName: plist["VolumeName"] as? String
        )
    }

    /// The tail of a failure, minus the progress chatter, so an error box carries
    /// the reason rather than a transcript.
    private static func lastMeaningfulLines(_ text: String) -> String {
        let noise = ["Started erase", "Unmounting disk", "Mounting disk", "Waiting for partitions"]
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !noise.contains(where: { line.hasPrefix($0) }) }
            .suffix(3)
            .joined(separator: "\n")
    }

    // MARK: - Subprocess

    private struct CommandResult {
        let status: Int32
        let output: Data
        let errorText: String

        var outputText: String {
            String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
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

    /// Same as `run`, but hands each line of stdout to `onLine` as it arrives.
    ///
    /// `diskutil eraseDisk` narrates itself — "Unmounting disk", "Erasing",
    /// "Mounting disk" — and forwarding that is the difference between a progress
    /// sheet that says what it's doing and one that just spins. stderr is read
    /// after the fact: `diskutil` writes a few hundred bytes there at most, well
    /// inside the pipe buffer.
    private static func runStreaming(
        _ launchPath: String,
        _ arguments: [String],
        onLine: StepHandler?
    ) -> CommandResult {
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

        var collected = Data()
        var pending = ""
        let handle = outPipe.fileHandleForReading

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            collected.append(chunk)

            guard let onLine else { continue }
            pending += String(data: chunk, encoding: .utf8) ?? ""
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[pending.startIndex..<newline])
                    .trimmingCharacters(in: .whitespaces)
                pending = String(pending[pending.index(after: newline)...])
                if !line.isEmpty { onLine(line) }
            }
        }

        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            output: collected,
            errorText: String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private static func plist(from result: CommandResult) -> [String: Any]? {
        guard result.status == 0 else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: result.output, options: [], format: nil
        ) as? [String: Any]
    }
}
