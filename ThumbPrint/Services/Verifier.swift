import Foundation

struct VerificationReport {
    var sourceFileCount = 0
    var targetFileCount = 0
    var missing: [String] = []
    var sizeMismatches: [String] = []
    var timeMismatches: [String] = []

    /// Files the copy phase already reported as skipped. Listed separately so
    /// they read as a known problem rather than a second, mysterious one.
    var knownSkipped: [String] = []

    var discrepancyCount: Int {
        missing.count + sizeMismatches.count + timeMismatches.count
    }

    var passed: Bool { discrepancyCount == 0 }

    /// First few problems, for a summary line that doesn't run off the window.
    func firstProblems(limit: Int = 5) -> [String] {
        (missing.map { "Missing: \($0)" }
            + sizeMismatches.map { "Wrong size: \($0)" }
            + timeMismatches.map { "Wrong date: \($0)" })
            .prefix(limit)
            .map { $0 }
    }
}

enum Verifier {
    /// Re-reads the target and confirms it actually matches the source.
    ///
    /// Deliberately re-enumerates rather than trusting what the copy phase
    /// believed it wrote — the point is to catch the case where the write was
    /// accepted but the data didn't land.
    static func verify(
        sourceIndex: FileIndex,
        targetVolume: URL,
        skipped: [String] = [],
        isCancelled: () -> Bool = { false },
        onCount: (Int) -> Void = { _ in }
    ) throws -> VerificationReport {
        let targetIndex = try FileIndex.build(
            at: targetVolume,
            isCancelled: isCancelled,
            onCount: onCount
        )

        var report = VerificationReport()
        report.sourceFileCount = sourceIndex.fileCount
        report.targetFileCount = targetIndex.fileCount
        report.knownSkipped = skipped

        // Paths already reported as skipped during the copy shouldn't be
        // counted twice — they're surfaced under their own heading.
        let skippedPaths = Set(skipped.map { $0.components(separatedBy: " — ").first ?? $0 })

        for entry in sourceIndex.fileEntries {
            if isCancelled() { throw CancellationError() }
            guard !skippedPaths.contains(entry.relativePath) else { continue }

            guard let copied = targetIndex.entries[entry.relativePath], !copied.isDirectory else {
                report.missing.append(entry.relativePath)
                continue
            }

            if copied.size != entry.size {
                report.sizeMismatches.append(entry.relativePath)
                continue
            }

            let drift = abs(copied.modificationDate.timeIntervalSince(entry.modificationDate))
            if drift > FileIndex.modificationTolerance {
                report.timeMismatches.append(entry.relativePath)
            }
        }

        return report
    }
}
