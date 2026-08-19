import SwiftUI

struct SummaryView: View {
    enum Outcome {
        case finished(CloneSummary)
        case failed(String)
        case cancelled
    }

    let outcome: Outcome
    let onDone: () -> Void

    /// Set when the run left the backup drive in a state that looks healthier
    /// than it is — currently only an interrupted Exact Clone.
    var targetWarning: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            PageHeader(
                title: title,
                subtitle: subtitle,
                systemImage: symbolName,
                tint: tint
            )

            if let targetWarning {
                NoticeBox(kind: .warning, text: targetWarning, isSelectable: true)
            }

            switch outcome {
            case .finished(let summary):
                statsRow(summary)
                problems(summary)

            case .failed(let message):
                ScrollView {
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .card()

            case .cancelled:
                // The resume reassurance is true of Fast Sync and false of a
                // half-written raw clone, so it goes away when the warning above
                // has already explained that the drive needs re-cloning.
                NoticeBox(
                    kind: .info,
                    text: targetWarning == nil
                        ? "The backup was stopped before it finished, so “\(targetNameOrDrive)” is incomplete. Run it again when you're ready — Fast Sync picks up where it left off."
                        : "The clone was stopped before it finished."
                )
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .pageLayout()
    }

    // MARK: - Header content

    private var symbolName: String {
        switch outcome {
        case .finished(let summary):
            return summary.succeededCleanly ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "stop.circle.fill"
        }
    }

    private var tint: Color {
        switch outcome {
        case .finished(let summary):
            return summary.succeededCleanly ? .green : .orange
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }

    private var title: String {
        switch outcome {
        case .finished(let summary):
            return summary.succeededCleanly ? "Backup complete" : "Finished with problems"
        case .failed:
            return "Backup failed"
        case .cancelled:
            return "Backup stopped"
        }
    }

    private var subtitle: String {
        switch outcome {
        case .finished(let summary):
            return "\(summary.sourceName) → \(summary.targetName) · \(DurationFormat.string(summary.duration))"
        case .failed:
            return "Nothing further was written."
        case .cancelled:
            return "You cancelled the copy."
        }
    }

    private var targetNameOrDrive: String {
        if case .finished(let summary) = outcome { return summary.targetName }
        return "the backup drive"
    }

    // MARK: - Stats

    private func statsRow(_ summary: CloneSummary) -> some View {
        StatRow {
            if summary.mode == .fastSync {
                StatTile(value: "\(summary.filesCopied)", title: "Files copied")
                StatDivider()
                StatTile(value: ByteFormat.string(summary.bytesCopied), title: "Data written")
                StatDivider()
                StatTile(
                    value: "\(summary.itemsDeleted)",
                    title: "Items deleted",
                    tint: summary.itemsDeleted > 0 ? .orange : .primary
                )
            } else {
                StatTile(value: ByteFormat.string(summary.bytesCopied), title: "Data written")
                StatDivider()
                StatTile(value: DurationFormat.string(summary.duration), title: "Duration")
            }
        }
    }

    // MARK: - Problems

    @ViewBuilder
    private func problems(_ summary: CloneSummary) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if let verification = summary.verification {
                if verification.passed && summary.skipped.isEmpty {
                    NoticeBox(
                        kind: .success,
                        text: "Verified — all \(verification.sourceFileCount) files are present on the backup with matching sizes and dates."
                    )
                } else if !verification.passed {
                    NoticeBox(
                        kind: .warning,
                        text: "Verification found \(verification.discrepancyCount) problem\(verification.discrepancyCount == 1 ? "" : "s"). This backup should not be trusted until it's re-run."
                    )
                }
            }

            if !summary.skipped.isEmpty || !(summary.verification?.passed ?? true) {
                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel("Details", systemImage: "text.alignleft")

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(problemLines(summary), id: \.self) { line in
                                Text(line)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 148)
                    .card()
                }
            }
        }
    }

    private func problemLines(_ summary: CloneSummary) -> [String] {
        var lines = summary.skipped.map { "Skipped: \($0)" }
        if let verification = summary.verification {
            lines += verification.firstProblems(limit: 50)
            let shown = min(verification.discrepancyCount, 50)
            if verification.discrepancyCount > shown {
                lines.append("…and \(verification.discrepancyCount - shown) more.")
            }
        }
        return lines
    }
}
