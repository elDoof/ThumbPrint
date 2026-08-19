import AppKit
import SwiftUI

/// The confirmation gate. Nothing has been written at this point, and the Start
/// button here is the only way to change that.
struct PreflightView: View {
    let report: PreflightReport
    let onStart: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            PageHeader(
                title: report.isNoOp ? "Nothing to copy" : "Check before you start",
                subtitle: report.mode.title,
                systemImage: report.isNoOp ? "checkmark.circle" : "list.clipboard",
                tint: report.isNoOp ? .green : .accentColor
            )

            routeSummary

            if report.isNoOp {
                NoticeBox(
                    kind: .success,
                    text: "“\(report.target.name)” already matches the source. There's nothing to copy or delete."
                )
            } else {
                statsRow
            }

            notices

            Spacer(minLength: 0)
            footer
        }
        .pageLayout()
    }

    // MARK: - Route

    /// The single most important thing on this screen: which drive is about to
    /// be overwritten. Given the most visual weight for that reason.
    private var routeSummary: some View {
        HStack(spacing: 0) {
            driveBadge(
                name: report.source.name,
                caption: "Source · read only",
                symbol: "externaldrive.fill",
                tint: .secondary
            )

            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 44)

            driveBadge(
                name: report.target.name,
                caption: "Backup · will be changed",
                symbol: "externaldrive.fill.badge.plus",
                tint: .accentColor
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 17)
        .cardEdgeToEdge()
    }

    private func driveBadge(
        name: String,
        caption: String,
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 27))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)

            Text(name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(caption)
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
            if report.mode == .fastSync {
                StatTile(
                    value: "\(report.filesToCopy)",
                    title: "To copy",
                    caption: ByteFormat.string(report.bytesToCopy)
                )
                StatDivider()
                StatTile(
                    value: "\(report.itemsToDelete)",
                    title: "To delete",
                    caption: ByteFormat.string(report.bytesToDelete),
                    tint: report.itemsToDelete > 0 ? .orange : .primary
                )
                StatDivider()
                StatTile(
                    value: "\(report.foldersToCreate)",
                    title: "New folders"
                )
            } else {
                StatTile(
                    value: ByteFormat.string(report.diskSizeToClone),
                    title: "Disk size",
                    caption: "written in full"
                )
                StatDivider()
                StatTile(
                    value: ByteFormat.string(report.source.usedCapacity),
                    title: "In use",
                    caption: "on the source"
                )
            }
        }
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if !report.blockers.isEmpty || !report.warnings.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(report.blockers, id: \.self) { blocker in
                        NoticeBox(kind: .blocker, text: blocker)
                    }
                    ForEach(report.warnings, id: \.self) { warning in
                        NoticeBox(kind: .warning, text: warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 186)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Back", action: onBack)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

            if report.sourceNeedsRepair {
                Button("Open Disk Utility…", action: openDiskUtility)
                    .controlSize(.large)
                    .help("ThumbPrint never repairs a drive itself. Use Disk Utility's First Aid on “\(report.source.name)”, then try again.")
            }

            Spacer()

            if report.isNoOp {
                Button("Done", action: onBack)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else {
                Button(startTitle, action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!report.canProceed)
                    .controlSize(.large)
            }
        }
    }

    private var startTitle: String {
        report.mode == .exactClone ? "Erase and Clone" : "Start Backup"
    }

    /// Hands the user off to Apple's repair tool rather than repairing here.
    private func openDiskUtility() {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") {
            workspace.open(url)
        } else {
            workspace.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
        }
    }
}
