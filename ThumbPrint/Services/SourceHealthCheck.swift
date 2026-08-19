import Foundation

/// Read-only corruption screening for the source volume.
///
/// Every signal here is a byproduct of the indexing pass the app already runs,
/// so screening costs nothing extra: no unmount, no admin rights, and — the
/// property the whole app rests on — no modification of the source.
///
/// This exists because FAT32 and exFAT have no journal and no checksums. A
/// damaged drive mounts, plays, and reads normally right up until you touch the
/// bad region. "It seems fine" is not evidence that it is, so a backup tool
/// can't assume its source is healthy.
///
/// Only *unambiguous* damage is reported here. Ambiguous conditions — a single
/// unreadable file, which may just be a permissions problem — stay warnings in
/// `PreflightReport` rather than becoming blockers.
struct SourceHealthReport {
    var findings: [String] = []
    var unreadableCount = 0

    var isHealthy: Bool { findings.isEmpty }

    static func evaluate(index: FileIndex, drive: Drive) -> SourceHealthReport {
        var report = SourceHealthReport()
        report.unreadableCount = index.unreadablePaths.count

        // 1. Control characters or null bytes in a name.
        //    A working filesystem cannot produce these. A corrupt directory
        //    table routinely does, because the raw bytes stop being valid
        //    directory entries and get read as text anyway.
        let mangled = index.entries.keys.filter(containsControlCharacters).sorted()
        if !mangled.isEmpty {
            let example = sanitizedForDisplay(mangled[0])
            let subject = mangled.count == 1
                ? "1 item on “\(drive.name)” has a name"
                : "\(mangled.count) items on “\(drive.name)” have names"
            report.findings.append(
                "\(subject) containing invalid characters, which means the drive's directory table is damaged. For example: \(example)"
            )
        }

        // 2. Files adding up to more than the volume says is in use.
        //    A file's logical size can never exceed the space allocated to it,
        //    so the sum of file sizes can never exceed used space. When it does,
        //    separate files are claiming the same blocks — cross-linked clusters.
        //    The 2% margin absorbs rounding and the caches we skip at the root.
        let indexed = index.totalBytes
        let used = drive.usedCapacity
        if used > 0, indexed > Int64(Double(used) * 1.02) {
            report.findings.append(
                "Files on “\(drive.name)” add up to \(ByteFormat.string(indexed)), but the drive reports only \(ByteFormat.string(used)) in use. Separate files are claiming the same space on disk (cross-linked clusters), so their contents can't all be correct."
            )
        }

        // 3. A single file larger than the whole volume. Rare, but free to check
        //    and conclusive when it happens.
        if let impossible = index.fileEntries.first(where: { $0.size > drive.totalCapacity }) {
            report.findings.append(
                "\(sanitizedForDisplay(impossible.relativePath)) claims to be \(ByteFormat.string(impossible.size)), which is larger than the entire \(ByteFormat.string(drive.totalCapacity)) drive. Its directory entry is corrupt."
            )
        }

        return report
    }

    // MARK: - Helpers

    private static func containsControlCharacters(_ path: String) -> Bool {
        path.unicodeScalars.contains { scalar in
            // C0 controls and DEL. Legal filenames never contain these.
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    /// Renders a damaged name safely — raw control bytes must never reach the
    /// UI, where they would corrupt the layout or simply be invisible.
    private static func sanitizedForDisplay(_ path: String) -> String {
        let cleaned = String(String.UnicodeScalarView(path.unicodeScalars.map { scalar in
            (scalar.value < 0x20 || scalar.value == 0x7F) ? Unicode.Scalar(0xFFFD)! : scalar
        }))
        return "“\(cleaned.prefix(60))”"
    }
}
