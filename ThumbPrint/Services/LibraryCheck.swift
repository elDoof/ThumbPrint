import Foundation

/// Read-only detection of a DJ library on a volume, and whether its exported
/// database still describes the audio sitting next to it.
///
/// Every signal here is derived from a `FileIndex` the app has already built, so
/// screening costs no extra I/O, needs no admin rights, and — the property the
/// whole app rests on — never modifies the drive. Same reasoning as
/// `SourceHealthReport`.
///
/// This exists because a player does not read the drive's folders. A CDJ reads
/// `PIONEER/rekordbox/export.pdb`; Serato reads `_Serato_/database V2`. Tracks
/// dragged on in Finder, or added in rekordbox and never re-exported, are
/// therefore present on the drive, copied faithfully by any backup, and still
/// invisible on the player. From the far side that is indistinguishable from a
/// broken backup — which is exactly what happened twice on 2026-08-11/12, when
/// neither report turned out to be a ThumbPrint fault. This check is the app
/// looking at both halves and saying so before the drive leaves the house.
struct LibraryReport {
    enum Kind: String, CaseIterable {
        case rekordbox
        case serato

        /// Path relative to the volume root, matched case-insensitively: FAT32
        /// and exFAT are case-insensitive, so whichever case a given drive
        /// happens to store is not something to depend on.
        var databasePath: String {
            switch self {
            case .rekordbox: return "PIONEER/rekordbox/export.pdb"
            case .serato: return "_Serato_/database V2"
            }
        }

        var displayName: String {
            switch self {
            case .rekordbox: return "rekordbox"
            case .serato: return "Serato"
            }
        }

        /// What reads this database, phrased for a warning aimed at a DJ.
        var readerDescription: String {
            switch self {
            case .rekordbox: return "CDJs and XDJs"
            case .serato: return "Serato"
            }
        }
    }

    struct Library {
        let kind: Kind
        let databasePath: String
        let databaseModified: Date

        /// Audio files modified later than the database, beyond `staleTolerance`.
        /// Sorted newest first.
        var newerAudio: [FileIndex.Entry] = []

        var isStale: Bool { !newerAudio.isEmpty }

        /// The newest audio file on the drive that the database predates.
        var newestAudioDate: Date? { newerAudio.first?.modificationDate }
    }

    var libraries: [Library] = []
    var audioFileCount = 0

    var hasLibrary: Bool { !libraries.isEmpty }
    var hasAudio: Bool { audioFileCount > 0 }
    var staleLibraries: [Library] { libraries.filter { $0.isStale } }

    func library(_ kind: Kind) -> Library? {
        libraries.first { $0.kind == kind }
    }
}

// MARK: - Evaluating

extension LibraryReport {
    /// An export writes the database and copies the audio as one operation, and
    /// which of the two lands last is **not** something this project has
    /// verified against a real rekordbox export. An hour of slack means a long
    /// export can't trip the check on write ordering alone, while the case that
    /// matters — a track dragged on days or weeks later — still does.
    ///
    /// If this ever produces a false positive straight after an export, that
    /// ordering assumption is the thing to go and measure.
    static let staleTolerance: TimeInterval = 3600

    /// Deliberately broad. A file a player can't decode still tells us the DJ
    /// put music on this drive after the last export, which is the signal.
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "aif", "aiff", "aifc", "wav", "wave",
        "flac", "alac", "ogg", "opus", "wma", "mp4",
    ]

    static func evaluate(index: FileIndex) -> LibraryReport {
        var report = LibraryReport()

        let databasePaths = Dictionary(
            uniqueKeysWithValues: Kind.allCases.map { ($0.databasePath.lowercased(), $0) }
        )

        var audio: [FileIndex.Entry] = []
        var databases: [Kind: FileIndex.Entry] = [:]

        for entry in index.fileEntries {
            if let kind = databasePaths[entry.relativePath.lowercased()] {
                databases[kind] = entry
                continue
            }
            if isAudio(entry.relativePath) {
                audio.append(entry)
            }
        }

        report.audioFileCount = audio.count

        for kind in Kind.allCases {
            guard let database = databases[kind] else { continue }

            var library = Library(
                kind: kind,
                databasePath: database.relativePath,
                databaseModified: database.modificationDate
            )
            let cutoff = database.modificationDate.addingTimeInterval(staleTolerance)
            library.newerAudio = audio
                .filter { $0.modificationDate > cutoff }
                .sorted { $0.modificationDate > $1.modificationDate }

            report.libraries.append(library)
        }

        return report
    }

    private static func isAudio(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent

        // AppleDouble sidecars carry the real file's extension and track its
        // modification date, so counting one would let a metadata stub stand in
        // as the drive's newest track.
        //
        // Belt and braces, knowingly: measured on both exFAT and APFS,
        // `FileManager`'s enumerator does not return `._` files at all, so a
        // `FileIndex` never contains one and this guard cannot fire today. It
        // stays so that changing how indexing works can't quietly promote a
        // sidecar to a track.
        guard !name.hasPrefix("._") else { return false }

        return audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

// MARK: - Advisory copy

extension LibraryReport {
    /// Preflight notes for a drive.
    ///
    /// Warnings, never blockers. A stale library is a condition of the *source*
    /// that a backup faithfully reproduces; refusing to copy would leave the DJ
    /// with neither a fixed library nor a backup, which is strictly worse than
    /// copying and saying what's wrong.
    func notes(for drive: Drive) -> [String] {
        var notes: [String] = []

        for library in staleLibraries {
            let count = library.newerAudio.count
            let subject = count == 1 ? "1 audio file" : "\(count) audio files"
            var note = "\(subject) on “\(drive.name)” \(count == 1 ? "is" : "are") newer than its \(library.kind.displayName) library"

            if let newest = library.newestAudioDate {
                note += ", the newest by \(AgeFormat.gap(from: library.databaseModified, to: newest))"
            }

            note += ". If \(count == 1 ? "it was" : "they were") added outside \(library.kind.displayName), "
            note += "\(library.kind.readerDescription) won't see \(count == 1 ? "it" : "them") — "
            note += "they read \(library.databasePath), not the drive's folders. "
            note += "Re-export from \(library.kind.displayName) to include \(count == 1 ? "it" : "them"). "
            note += "The backup copies the file\(count == 1 ? "" : "s") either way."

            notes.append(note)
        }

        // Only worth saying when there's music to be invisible. A drive with
        // neither a library nor audio is just an empty stick.
        if hasAudio && !hasLibrary {
            notes.append(
                "“\(drive.name)” holds \(audioFileCount) audio file\(audioFileCount == 1 ? "" : "s") but no rekordbox or Serato library. The backup will be a faithful copy, but a player needs an exported library to show any of it."
            )
        }

        return notes
    }
}
