import SwiftUI

/// The result of a Compare run.
///
/// Unlike every other screen in the app this one is a dead end — there is no
/// action on the far side of it, because nothing was or will be written. So it
/// spends its space on the finding itself rather than on a decision.
struct ComparisonView: View {
    let report: ComparisonReport
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            PageHeader(
                title: report.isIdentical ? "The drives match" : "\(report.files.differenceCount) difference\(report.files.differenceCount == 1 ? "" : "s")",
                subtitle: CloneMode.compareOnly.title,
                systemImage: report.isIdentical ? "equal.circle" : "arrow.left.arrow.right.circle",
                tint: report.isIdentical ? .green : .accentColor
            )

            driveHeader

            if report.isIdentical {
                NoticeBox(
                    kind: .success,
                    text: "Every file on “\(report.left.name)” is on “\(report.right.name)” at the same size and time, and neither drive has anything the other doesn't. \(report.files.identicalCount) file\(report.files.identicalCount == 1 ? "" : "s") checked."
                )
            } else {
                statsRow
            }

            details

            Spacer(minLength: 0)
            footer
        }
        .pageLayout()
    }

    // MARK: - Drives

    /// Both drives get identical treatment — same symbol, same tint, same
    /// caption. Compare has no direction, and the layout shouldn't imply one.
    private var driveHeader: some View {
        HStack(spacing: 0) {
            driveBadge(report.left)

            Image(systemName: "arrow.left.arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 44)

            driveBadge(report.right)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 17)
        .cardEdgeToEdge()
    }

    private func driveBadge(_ drive: Drive) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 27))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Text(drive.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Read only")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    // MARK: - Stats

    private var statsRow: some View {
        StatRow {
            StatTile(
                value: "\(report.files.onlyOnLeft.count)",
                title: "Only on \(report.left.name)",
                caption: ByteFormat.string(report.files.bytesOnlyOnLeft),
                tint: report.files.onlyOnLeft.isEmpty ? .primary : .orange
            )
            StatDivider()
            StatTile(
                value: "\(report.files.onlyOnRight.count)",
                title: "Only on \(report.right.name)",
                caption: ByteFormat.string(report.files.bytesOnlyOnRight),
                tint: report.files.onlyOnRight.isEmpty ? .primary : .orange
            )
            StatDivider()
            StatTile(
                value: "\(report.files.differing.count)",
                title: "Differ",
                caption: "same name"
            )
            StatDivider()
            StatTile(
                value: "\(report.files.identicalCount)",
                title: "Identical"
            )
        }
    }

    // MARK: - Details

    /// Notes and the difference listing share one scroll area: on a drive that
    /// differs in thousands of files the list would otherwise push the notes —
    /// the part that explains *why* — off the bottom of the window.
    @ViewBuilder
    private var details: some View {
        if !report.notes.isEmpty || !report.isIdentical {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(report.notes, id: \.self) { note in
                        NoticeBox(kind: .info, text: note)
                    }

                    fileGroup(
                        "Only on \(report.left.name)",
                        systemImage: "arrow.left.circle",
                        entries: report.files.onlyOnLeft
                    )
                    fileGroup(
                        "Only on \(report.right.name)",
                        systemImage: "arrow.right.circle",
                        entries: report.files.onlyOnRight
                    )
                    fileGroup(
                        "Different on each drive",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                        entries: report.files.differing
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 246)
        }
    }

    /// Rendering every path of a 50k-file divergence would build 50k text views
    /// to no benefit — nobody reads past the first screenful, and the count above
    /// already carries the magnitude. The cap is stated in the UI rather than
    /// applied silently, so a truncated list can't be mistaken for a complete one.
    private static let listLimit = 100

    @ViewBuilder
    private func fileGroup(
        _ title: String,
        systemImage: String,
        entries: [FileIndex.Entry]
    ) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("\(title) · \(entries.count)", systemImage: systemImage)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entries.prefix(Self.listLimit), id: \.relativePath) { entry in
                        HStack(spacing: 8) {
                            Text(entry.relativePath)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)

                            Spacer(minLength: 8)

                            if !entry.isDirectory {
                                Text(ByteFormat.string(entry.size))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if entries.count > Self.listLimit {
                        Text("…and \(entries.count - Self.listLimit) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .cardEdgeToEdge()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Label("Nothing was written to either drive", systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }
}
