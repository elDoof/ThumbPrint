import Foundation

/// What a Compare run found. Nothing is written to either drive to produce this.
///
/// The two drives are `left` and `right`, not source and target. Compare has no
/// direction — naming one of them the source would imply the other is about to
/// be changed, which is the one thing this mode promises not to do.
struct ComparisonReport {
    let left: Drive
    let right: Drive

    let files: FileComparison
    let leftLibrary: LibraryReport
    let rightLibrary: LibraryReport

    /// Advisory copy, in the order it should be read.
    var notes: [String] = []

    /// Paths that couldn't be read on either drive. A comparison built from a
    /// partial index would quietly report the unreadable files as "missing from
    /// the other drive", so this can't be left out of the summary.
    var unreadable: [String] = []

    var isIdentical: Bool { files.isIdentical }
}

extension ComparisonReport {
    static func make(
        left: Drive,
        right: Drive,
        leftIndex: FileIndex,
        rightIndex: FileIndex
    ) -> ComparisonReport {
        var report = ComparisonReport(
            left: left,
            right: right,
            files: FileIndex.compare(left: leftIndex, right: rightIndex),
            leftLibrary: LibraryReport.evaluate(index: leftIndex),
            rightLibrary: LibraryReport.evaluate(index: rightIndex)
        )

        report.unreadable = leftIndex.unreadablePaths.map { "\(left.name): \($0)" }
            + rightIndex.unreadablePaths.map { "\(right.name): \($0)" }

        // Read first, because it changes how much the rest of the screen can be
        // trusted: differences on a partially-read drive may be artefacts.
        if !report.unreadable.isEmpty {
            let count = report.unreadable.count
            report.notes.append(
                "\(count) item\(count == 1 ? "" : "s") couldn't be read while indexing, so \(count == 1 ? "it may" : "they may") show as missing from the other drive when \(count == 1 ? "it is" : "they are") simply unreadable here."
            )
        }

        // A library on one drive and not the other is the single most useful
        // cross-drive finding: it's the difference between a backup that plays
        // in a CDJ and a backup that doesn't.
        for kind in LibraryReport.Kind.allCases {
            let onLeft = report.leftLibrary.library(kind) != nil
            let onRight = report.rightLibrary.library(kind) != nil
            guard onLeft != onRight else { continue }

            let has = onLeft ? left : right
            let hasNot = onLeft ? right : left
            report.notes.append(
                "“\(has.name)” has a \(kind.displayName) library and “\(hasNot.name)” doesn't. \(kind.readerDescription) will read one drive as a library and the other as a folder of files."
            )
        }

        // Per-drive library staleness, reusing the preflight wording — the fact
        // is the same whether it's found before a copy or during a comparison.
        report.notes.append(contentsOf: report.leftLibrary.notes(for: left))
        report.notes.append(contentsOf: report.rightLibrary.notes(for: right))

        if left.formatDescription != right.formatDescription {
            report.notes.append(
                "Different formats: “\(left.name)” is \(left.formatDescription), “\(right.name)” is \(right.formatDescription)."
            )
        }

        return report
    }
}
