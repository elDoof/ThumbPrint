import Foundation

/// Read-only filesystem verification of a volume, using the same checker that
/// Disk Utility's First Aid runs.
///
/// This exists because the index-derived screening in `SourceHealthReport` can
/// only see damage that surfaces in file *metadata* — mangled names, size sums
/// that exceed used space, impossible file sizes. It cannot see a cross-linked
/// cluster chain, a cluster pointer out of range, or a directory entry that no
/// longer describes a directory. A drive with exactly those faults passed the
/// metadata screen and was backed up, which is why this check now exists.
///
/// `diskutil verifyVolume` runs `fsck_msdos -n` (or the equivalent for the
/// volume's format). The `-n` answers "no" to every repair prompt, so the check
/// cannot write to the volume — the one rule holds. It *does* briefly unmount
/// and remount the volume, which is why it runs during analysis, before
/// anything has been written anywhere.
enum FilesystemCheck {
    enum Outcome: Equatable {
        case passed

        /// The checker found damage it would have had to repair.
        case damaged(detail: String)

        /// The check couldn't be completed — the volume was busy, diskutil
        /// refused, the user cancelled. This is *not* evidence of damage, so it
        /// warns rather than blocks: a checker that won't run must not make the
        /// app unusable.
        case inconclusive(reason: String)
    }

    struct Report {
        var outcome: Outcome = .inconclusive(reason: "not run")

        /// False when the volume didn't come back at its original mount point
        /// after the check unmounted it. Nothing can safely proceed from there.
        var volumeRemounted = true

        var passed: Bool { outcome == .passed }
    }

    static func verify(volumeURL: URL, isCancelled: () -> Bool = { false }) -> Report {
        var report = Report()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["verifyVolume", volumeURL.path]

        // Both streams into one pipe: diskutil splits its narration across
        // stdout and stderr, and the fsck exit-code line must not be lost.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            report.outcome = .inconclusive(reason: error.localizedDescription)
            return report
        }

        // Drain as output arrives rather than after exit, so a full pipe buffer
        // can't deadlock the checker. `availableData` blocks until the next
        // write, so cancellation is noticed at diskutil's next line of
        // narration rather than instantly — good enough, and it keeps this free
        // of a second thread and the data race that would come with it.
        let handle = pipe.fileHandleForReading
        var output = ""
        var cancelled = false

        while true {
            if isCancelled() {
                cancelled = true
                process.terminate()
                break
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            output += String(data: chunk, encoding: .utf8) ?? ""
        }

        if !cancelled {
            output += String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        process.waitUntilExit()

        // Checked after the process exits: the remount is the last thing
        // diskutil does.
        report.volumeRemounted = FileManager.default.fileExists(atPath: volumeURL.path)

        if cancelled {
            report.outcome = .inconclusive(reason: "the check was cancelled")
            return report
        }

        report.outcome = interpret(exitCode: process.terminationStatus, output: output)
        return report
    }

    // MARK: - Interpreting the checker's output

    private static func interpret(exitCode: Int32, output: String) -> Outcome {
        let lines = output.components(separatedBy: .newlines)

        // The underlying checker's own exit code is the authoritative answer,
        // and diskutil reports it verbatim. Anything non-zero means fsck found
        // something it would have needed to repair. Prefer this over diskutil's
        // exit code, which also covers failures to even run the check.
        if let marker = lines.first(where: { $0.contains("File system check exit code is") }),
           let code = marker.split(separator: " ").compactMap({ Int($0) }).last {
            return code == 0 ? .passed : .damaged(detail: findings(in: lines))
        }

        if exitCode == 0 { return .passed }

        let reason = lines
            .first { $0.hasPrefix("Error:") || $0.contains("could not") }?
            .trimmingCharacters(in: .whitespaces)
        return .inconclusive(reason: reason ?? "diskutil exited with code \(exitCode)")
    }

    /// The lines a person can actually act on, minus fsck's bookkeeping.
    private static func findings(in lines: [String]) -> String {
        let signals = [
            "does not appear", "Invalid", "invalid", "Cross", "cross-linked",
            "out of range", "Orphan", "orphan", "Incorrect", "Bad ", "bad ",
            "CORRUPT", "Unrecoverable", "truncated", "Dirty", "mismatch",
        ]

        let interesting = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("**") else { return false }
            // "Warning: 7555 files, 11529536 KiB free (720596 clusters)" is the
            // free-space summary fsck always prints — informational, not a fault.
            if trimmed.contains(" files,") && trimmed.contains("free") { return false }
            if trimmed.hasPrefix("Correct?") { return false }
            if trimmed.hasPrefix("Warning:") { return true }
            return signals.contains { trimmed.contains($0) }
        }

        let shown = interesting.prefix(5).map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "Warning: ", with: "")
        }

        if shown.isEmpty {
            return "The filesystem checker reported errors but gave no detail."
        }

        var detail = shown.joined(separator: "\n")
        if interesting.count > shown.count {
            detail += "\n…and \(interesting.count - shown.count) more."
        }
        return detail
    }
}
