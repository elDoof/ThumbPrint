import AppKit
import DiskArbitration
import Foundation

/// Enumerates mounted volumes and keeps the list current as drives come and go.
///
/// This type is also the single place the "never touch the system disk" rule is
/// enforced: a volume that fails `drive(for:)` never becomes a `Drive`, so it
/// can't reach a picker, a preflight check, or an engine.
@MainActor
@Observable
final class DriveScanner {
    private(set) var drives: [Drive] = []

    private let session: DASession?

    /// `deinit` is nonisolated and so can't touch MainActor-isolated storage.
    /// Parking the tokens in their own object lets them be released correctly
    /// when the scanner goes away.
    private let observers = ObserverTokens()

    private static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeIsInternalKey,
        .volumeIsBrowsableKey,
        .volumeIsReadOnlyKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeUUIDStringKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    init() {
        session = DASessionCreate(kCFAllocatorDefault)
        startObserving()
        rescan()
    }

    // MARK: - Scanning

    func rescan() {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.resourceKeys,
            options: [.skipHiddenVolumes]
        ) ?? []

        drives = urls
            .compactMap(drive(for:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Returns `true` if the volume is still mounted. Engines poll this so an
    /// unplugged drive surfaces as a clear error instead of a stream of EIO.
    func isStillMounted(_ drive: Drive) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: drive.volumeURL.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // MARK: - Eligibility

    private func drive(for url: URL) -> Drive? {
        // The boot volume is never a candidate, in either direction.
        guard url.path != "/" else { return nil }
        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }

        // Removable-or-ejectable is the safety gate, and it is sufficient: a
        // built-in disk is neither, so Macintosh HD and any internal secondary
        // drive can never appear here.
        //
        // `volumeIsInternal` is deliberately NOT part of the gate. Attached disk
        // images report internal == true despite being removable and ejectable,
        // and USB enclosures behind some hubs misreport their bus the same way.
        // Requiring it would make the app show "no drives connected" while a
        // drive is plainly mounted — a far more likely failure than a built-in
        // disk somehow reporting itself as ejectable.
        let isRemovable = values.volumeIsRemovable ?? false
        let isEjectable = values.volumeIsEjectable ?? false
        guard isRemovable || isEjectable else { return nil }

        // A Time Machine destination is never a sensible DJ backup target, and
        // mirroring onto one would destroy the backup history.
        guard !isTimeMachineVolume(url) else { return nil }

        // A disk image ThumbPrint has open is not a drive the user can pick.
        //
        // Belt and braces: images are attached with `-nobrowse` at a private
        // mount point, and measurement on 2026-08-14 confirms such a mount never
        // appears in `mountedVolumeURLs` at all. But an attached image reports
        // both `removable` and `ejectable` as true, so if that ever changed it
        // would sail straight through the gate above and offer itself as a backup
        // target. Cheap to rule out explicitly.
        guard !url.path.hasPrefix(DiskImageStore.mountRoot.path) else { return nil }

        return Drive(
            volumeURL: url,
            name: values.volumeName ?? url.lastPathComponent,
            wholeDiskBSDName: wholeDiskBSDName(for: url),
            totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
            availableCapacity: Int64(values.volumeAvailableCapacity ?? 0),
            volumeUUID: values.volumeUUIDString,
            formatDescription: values.volumeLocalizedFormatDescription ?? "Unknown",
            isReadOnly: values.volumeIsReadOnly ?? false
        )
    }

    /// Detects both the classic (`Backups.backupdb`) and APFS-era
    /// (`.com.apple.timemachine.*`) markers Time Machine leaves at a volume root.
    private func isTimeMachineVolume(_ url: URL) -> Bool {
        let markers = [
            "Backups.backupdb",
            ".com.apple.timemachine.donotpresent",
            ".com.apple.timemachine.supported",
        ]
        let fm = FileManager.default
        return markers.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// Resolves the volume to its *whole disk* BSD name (`disk4`, not `disk4s1`).
    private func wholeDiskBSDName(for volumeURL: URL) -> String? {
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
              let wholeDisk = DADiskCopyWholeDisk(disk),
              let name = DADiskGetBSDName(wholeDisk)
        else { return nil }
        return String(cString: name)
    }

    // MARK: - Mount notifications

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]

        observers.tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rescan() }
            }
        }
    }
}

/// Owns block-based notification observers and unregisters them on release.
private final class ObserverTokens {
    var tokens: [NSObjectProtocol] = []

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens {
            center.removeObserver(token)
        }
    }
}
