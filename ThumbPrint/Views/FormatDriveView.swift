import AppKit
import SwiftUI

/// The erase sheet: the one place in ThumbPrint that destroys data it was not
/// asked to copy.
///
/// Shaped like `PreflightView` on purpose. That screen is the app's established
/// "read this, then confirm something irreversible" page, and an erase deserves
/// the same treatment rather than a one-line alert — the blockers and warnings
/// are the same kind of object, drawn with the same `NoticeBox`.
///
/// The Erase button is wired to an `EraseApproval`, which `FormatPreflight` only
/// mints when nothing is blocking. A disabled button is the visible half of that;
/// the type is the half that still holds if the button is ever mis-wired.
struct FormatDriveView: View {
    let drive: Drive

    /// The source side of the copy, if one is selected — the erase must refuse it.
    let source: Endpoint?
    /// Any disk image currently chosen, so one living on this drive blocks.
    let selectedImageURLs: [URL]

    let onErased: (Drive) -> Void
    let onCancel: () -> Void

    @State private var format: DiskFormat
    @State private var name: String
    @State private var disk: DiskFacts?
    @State private var phase: Phase = .confirming

    private enum Phase: Equatable {
        case confirming
        case erasing(String)
        case failed(String)
        case done(String)
    }

    /// What the physical disk looks like. Read once when the sheet opens, because
    /// gathering it means three `diskutil` calls.
    private struct DiskFacts: Equatable {
        var wholeDiskSize: Int64
        var siblings: [FormatPreflight.SiblingVolume]
    }

    init(
        drive: Drive,
        source: Endpoint?,
        selectedImageURLs: [URL],
        onErased: @escaping (Drive) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.drive = drive
        self.source = source
        self.selectedImageURLs = selectedImageURLs
        self.onErased = onErased
        self.onCancel = onCancel

        // Match the source's format when there is one. The standing default in
        // this project is to reproduce the drive being backed up rather than to
        // have an opinion about what a DJ should use.
        let preferred = source?.driveValue.flatMap { DiskFormat.matching($0.formatDescription) }
            ?? DiskFormat.matching(drive.formatDescription)
            ?? .exFAT
        _format = State(initialValue: preferred)
        _name = State(initialValue: FormatPreflight.sanitizedName(drive.name, format: preferred))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "Erase “\(drive.name)”",
                subtitle: "Reformat this drive as a backup drive",
                systemImage: "eraser.fill",
                tint: .red
            )

            switch phase {
            case .confirming:
                settings
                notices
            case .erasing(let step):
                progress(step)
            case .failed(let message):
                NoticeBox(kind: .blocker, text: message, isSelectable: true)
                Spacer(minLength: 0)
            case .done(let message):
                NoticeBox(kind: .success, text: message)
                Spacer(minLength: 0)
            }

            footer
        }
        .padding(Metrics.pagePadding)
        .frame(width: 480)
        .task { await loadDiskFacts() }
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel("Format", systemImage: "internaldrive")

                Picker("", selection: $format) {
                    ForEach(DiskFormat.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isWorking)

                Text(format.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 28, alignment: .top)
            }

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel("Name", systemImage: "tag")

                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                    .onChange(of: format) { _, newFormat in
                        // A name legal on exFAT may be too long for FAT32, and
                        // silently truncating it at erase time would leave the
                        // user looking at a drive with a name they didn't choose.
                        name = FormatPreflight.sanitizedName(name, format: newFormat)
                    }
            }
        }
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if disk == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the disk…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else {
            let rules = FormatPreflight.evaluate(facts)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(rules.blockers, id: \.self) { NoticeBox(kind: .blocker, text: $0) }
                    ForEach(rules.warnings, id: \.self) { NoticeBox(kind: .warning, text: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 210)
        }
    }

    private func progress(_ step: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView().progressViewStyle(.linear)
            Text(step.isEmpty ? "Erasing…" : step)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("Don't unplug the drive.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .failed = phase {
                Button("Open Disk Utility…", action: openDiskUtility)
                    .controlSize(.large)
            }

            Spacer()

            switch phase {
            case .confirming:
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                Button("Erase", action: erase)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(approval == nil)

            case .erasing:
                Button("Cancel") {}
                    .controlSize(.large)
                    .disabled(true)
                    .help("An erase can't be stopped part-way — a disk with half a partition map is worse than one that finished.")

            case .failed:
                Button("Close", action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)

            case .done:
                Button("Done", action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }

    // MARK: - State

    private var isWorking: Bool {
        if case .erasing = phase { return true }
        return false
    }

    private var facts: FormatPreflight.Facts {
        FormatPreflight.Facts(
            drive: drive,
            format: format,
            requestedName: name,
            wholeDiskSize: disk?.wholeDiskSize ?? drive.totalCapacity,
            siblings: disk?.siblings ?? [],
            sourceVolumePath: source?.driveValue?.volumeURL.path,
            sourceWholeDiskBSDName: source?.driveValue?.wholeDiskBSDName,
            selectedImageURLs: selectedImageURLs
        )
    }

    /// `nil` while the disk is still being read, and `nil` whenever a rule
    /// blocks. Both are reasons the button stays off.
    private var approval: EraseApproval? {
        guard disk != nil else { return nil }
        return FormatPreflight.approve(facts)
    }

    // MARK: - Actions

    private func loadDiskFacts() async {
        guard disk == nil, let bsdName = drive.wholeDiskBSDName else {
            // No physical disk means `FormatPreflight` will block anyway; set a
            // value so the sheet stops saying "reading" and shows that blocker.
            if disk == nil { disk = DiskFacts(wholeDiskSize: drive.totalCapacity, siblings: []) }
            return
        }

        let facts = await Task.detached(priority: .userInitiated) {
            DiskFacts(
                wholeDiskSize: DriveFormatter.wholeDiskSize(bsdName: bsdName),
                siblings: DriveFormatter.partitions(onWholeDisk: bsdName)
            )
        }.value

        // A disk that reports no size would make the FAT32 ceiling check
        // meaningless; fall back to the volume's own capacity, which is never
        // larger than the disk.
        disk = DiskFacts(
            wholeDiskSize: facts.wholeDiskSize > 0 ? facts.wholeDiskSize : drive.totalCapacity,
            siblings: facts.siblings
        )
    }

    private func erase() {
        guard let approval else { return }
        phase = .erasing("Starting…")

        Task {
            do {
                let erased = try await Task.detached(priority: .userInitiated) {
                    try DriveFormatter.erase(approval) { step in
                        Task { @MainActor in
                            if case .erasing = phase { phase = .erasing(step) }
                        }
                    }
                }.value

                phase = .done("“\(erased.name)” is now \(erased.formatDescription) and ready to back up to.")
                onErased(erased)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The same hand-off `PreflightView` makes for a damaged source. ThumbPrint
    /// having failed to erase a drive is not a reason to try harder with more
    /// privilege — it's a reason to point at the tool that owns the job.
    private func openDiskUtility() {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") {
            workspace.open(url)
        } else {
            workspace.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
        }
    }
}
