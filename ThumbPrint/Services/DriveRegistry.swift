import Foundation

/// The observable face of `DriveRegistryStore`.
///
/// Split from the store so the persistence rules stay testable as plain values;
/// this type only adds main-actor isolation, observation for the UI, and the
/// decision of when to write to disk.
@MainActor
@Observable
final class DriveRegistry {
    /// One registry per app. The alternative — threading it through `ContentView`
    /// into `CloneJob` — buys nothing here: there is a single window, and the file
    /// on disk is a single shared resource whichever way it's reached.
    static let shared = DriveRegistry()

    private(set) var store: DriveRegistryStore

    /// Set when the registry couldn't be written. Observable so it can be
    /// surfaced later if it ever matters, but deliberately not shown anywhere and
    /// never allowed to interrupt a job: failing to remember a drive must not
    /// stop, delay, or cast doubt on backing one up.
    private(set) var lastWriteError: String?

    private let url: URL

    init(url: URL = DriveRegistryStore.defaultStoreURL) {
        self.url = url
        self.store = DriveRegistryStore.load(from: url)
    }

    func record(for drive: Drive) -> DriveRecord? {
        store.record(for: drive)
    }

    /// Called as drives come and go. Cheap enough to write through on every
    /// change: the file holds one small object per drive a person owns.
    func noteSeen(_ drives: [Drive]) {
        guard !drives.isEmpty else { return }
        for drive in drives {
            store.noteSeen(drive)
        }
        persist()
    }

    func noteContents(_ drive: Drive, index: FileIndex) {
        store.noteContents(drive, index: index)
        persist()
    }

    func noteSync(
        source: Drive,
        target: Drive,
        filesCopied: Int,
        bytesCopied: Int64,
        duration: TimeInterval,
        verified: Bool,
        sourceIndex: FileIndex?
    ) {
        store.noteSync(
            source: source,
            target: target,
            filesCopied: filesCopied,
            bytesCopied: bytesCopied,
            duration: duration,
            verified: verified,
            sourceIndex: sourceIndex
        )
        persist()
    }

    /// A copy where the other side was a disk image file. Only the drive is
    /// recorded — see `DriveRegistryStore.noteImageSync`.
    func noteImageSync(
        drive: Drive,
        role: DriveRole,
        imageURL: URL,
        filesCopied: Int,
        bytesCopied: Int64,
        duration: TimeInterval,
        verified: Bool,
        sourceIndex: FileIndex?
    ) {
        store.noteImageSync(
            drive: drive,
            role: role,
            imageURL: imageURL,
            filesCopied: filesCopied,
            bytesCopied: bytesCopied,
            duration: duration,
            verified: verified,
            sourceIndex: sourceIndex
        )
        persist()
    }

    private func persist() {
        do {
            try store.save(to: url)
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
        }
    }
}
