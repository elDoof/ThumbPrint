import SwiftUI

struct CloneProgressView: View {
    let progress: CloneProgress
    let sourceName: String
    let targetName: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header
            progressBlock
            detailCard
            Spacer(minLength: 0)
            footer
        }
        .pageLayout()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(progress.stage.label)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            route
        }
    }

    /// Source → target, stated once and left on screen. During a long copy this
    /// is the only reminder of which drive is being written to.
    private var route: some View {
        HStack(spacing: 8) {
            driveChip(sourceName, symbol: "externaldrive.fill", tint: .secondary)

            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)

            driveChip(targetName, symbol: "externaldrive.fill.badge.plus", tint: .accentColor)
        }
    }

    private func driveChip(_ name: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    // MARK: - Progress

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Group {
                if progress.stage.isDeterminate {
                    ProgressView(value: progress.fractionCompleted)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .animation(.easeOut(duration: 0.25), value: progress.fractionCompleted)

            HStack(alignment: .firstTextBaseline) {
                if progress.stage.isDeterminate {
                    Text("\(Int(progress.fractionCompleted * 100))%")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: progress.fractionCompleted)
                } else {
                    Text("Scanning…")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let eta = progress.estimatedTimeRemaining {
                    Text("about \(eta) remaining")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Detail

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if progress.bytesTotal > 0 {
                detailRow(
                    "Copied",
                    "\(ByteFormat.string(progress.bytesCompleted)) of \(ByteFormat.string(progress.bytesTotal))"
                )
            }

            if progress.itemsTotal > 0 {
                detailRow("Items", "\(progress.itemsCompleted) of \(progress.itemsTotal)")
            } else if progress.itemsCompleted > 0 {
                detailRow("Items found", "\(progress.itemsCompleted)")
            }

            if progress.bytesPerSecond > 0 {
                detailRow("Speed", ByteFormat.rate(progress.bytesPerSecond))
            }

            if !progress.currentItem.isEmpty {
                if hasAnyStat { Divider().padding(.vertical, 9) }

                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel("Current file")
                    Text(progress.currentItem)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var hasAnyStat: Bool {
        progress.bytesTotal > 0 || progress.itemsTotal > 0
            || progress.itemsCompleted > 0 || progress.bytesPerSecond > 0
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.2), value: value)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if progress.stage == .rawCopying || progress.stage == .unmounting {
                Label("Don't unplug either drive", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
    }
}
