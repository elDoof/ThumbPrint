import SwiftUI

/// The update sheet. One screen, six states, and never on screen uninvited: the
/// automatic check only sets `isPresenting` when there is genuinely a newer
/// version the user hasn't already skipped.
struct UpdateSheet: View {
    @Bindable var controller: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
            footer
        }
        .padding(Metrics.pagePadding)
        .frame(width: 460)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle, .checking:
            header(
                "Checking for updates…",
                subtitle: currentVersionLine,
                symbol: "arrow.triangle.2.circlepath",
                tint: .accentColor
            )
            ProgressView().progressViewStyle(.linear)

        case .upToDate:
            header(
                "ThumbPrint is up to date",
                subtitle: currentVersionLine,
                symbol: "checkmark.circle",
                tint: .green
            )

        case .available(let release):
            header(
                "ThumbPrint \(release.version) is available",
                subtitle: currentVersionLine,
                symbol: "arrow.down.circle",
                tint: .accentColor
            )
            releaseNotes(release)

        case .working(let step):
            header(
                "Updating",
                subtitle: step,
                symbol: "arrow.down.circle",
                tint: .accentColor
            )
            ProgressView().progressViewStyle(.linear)
            Text("The download is verified against ThumbPrint's Developer ID before anything is replaced.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

        case .installed(let release):
            header(
                "Updated to \(release.version)",
                subtitle: "ThumbPrint will restart in a moment.",
                symbol: "checkmark.circle.fill",
                tint: .green
            )

        case .downloaded(let path, let reason):
            header(
                "Downloaded, not installed",
                subtitle: reason,
                symbol: "folder",
                tint: .orange
            )
            NoticeBox(
                kind: .info,
                text: "The update is in your Downloads folder:\n\(path)\n\nOpen it and drag ThumbPrint to Applications.",
                isSelectable: true
            )

        case .failed(let message):
            header(
                "Couldn't update",
                subtitle: currentVersionLine,
                symbol: "exclamationmark.triangle",
                tint: .orange
            )
            NoticeBox(kind: .warning, text: message, isSelectable: true)
        }
    }

    private func header(_ title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        PageHeader(title: title, subtitle: subtitle, systemImage: symbol, tint: tint)
    }

    private var currentVersionLine: String {
        controller.currentVersion.map { "You have \($0)." } ?? "This build has no version number."
    }

    /// The release body as GitHub wrote it. Rendered as Markdown when it parses,
    /// and as plain text when it doesn't — release notes are not worth a failure.
    private func releaseNotes(_ release: UpdateRelease) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if release.notes.isEmpty {
                    Text("No release notes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let markdown = try? AttributedString(
                    markdown: release.notes,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(markdown)
                        .font(.callout)
                        .textSelection(.enabled)
                } else {
                    Text(release.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.cardPadding)
        }
        .frame(maxHeight: 210)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch controller.state {
            case .available:
                Button("Skip This Version") { controller.skipCurrentRelease() }
                    .controlSize(.large)

                Spacer()

                Button("Later") { controller.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                Button("Install and Relaunch") { controller.install() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)

            case .downloaded(let path, _):
                Button("Show in Finder") { controller.revealInFinder(path) }
                    .controlSize(.large)

                Spacer()

                Button("Done") { controller.dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)

            case .failed:
                Button("Open Releases Page") { controller.openReleasesPage() }
                    .controlSize(.large)

                Spacer()

                Button("Done") { controller.dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)

            case .idle, .checking, .working, .installed:
                Spacer()
                Button("Done") { controller.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .disabled(controller.isBusy)

            case .upToDate:
                Spacer()
                Button("Done") { controller.dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }
}
