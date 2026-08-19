import SwiftUI
import UniformTypeIdentifiers

struct DrivePickerView: View {
    @Bindable var job: CloneJob
    let drives: [Drive]
    let registry: DriveRegistry

    /// Why a chosen file was refused. Some rules can be settled from the path
    /// alone, and saying so at the moment of choosing beats failing in analysis.
    @State private var selectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            hero
            modePicker

            if drives.isEmpty {
                emptyState
            } else {
                // Compare writes to neither drive, so the sections are named for
                // what they are — two drives being looked at — rather than for a
                // direction the mode doesn't have.
                driveSection(
                    title: job.mode.isInspection ? "Compare" : "Copy from",
                    systemImage: job.mode.isInspection ? "externaldrive.fill" : "arrow.up.circle.fill",
                    selection: $job.source,
                    excluded: job.target,
                    role: .from
                )

                driveSection(
                    title: job.mode.isInspection ? "With" : "Copy to",
                    systemImage: job.mode.isInspection ? "externaldrive.fill" : "arrow.down.circle.fill",
                    selection: $job.target,
                    excluded: job.source,
                    // A write-protected drive is a perfectly good thing to
                    // compare against, so the read-only exclusion applies only
                    // when something is actually going to be written.
                    isDestination: !job.mode.isInspection,
                    role: .to
                )
            }

            Spacer(minLength: 0)
            footer
        }
        .pageLayout()
        .onChange(of: job.mode) { _, newMode in
            // Exact Clone is a raw device copy and can't touch a file. Clearing
            // the selection is honest about that rather than leaving a row
            // selected that the Continue button silently refuses.
            guard !newMode.allowsImageEndpoints else { return }
            if job.source?.isImage == true { job.source = nil }
            if job.target?.isImage == true { job.target = nil }
        }
        .alert(
            "Can't use that file",
            isPresented: Binding(
                get: { selectionError != nil },
                set: { if !$0 { selectionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { selectionError = nil }
        } message: {
            Text(selectionError ?? "")
        }
    }

    // MARK: - Hero

    /// Start screen only. This is the one moment the app has nothing to report,
    /// so it can afford to introduce itself; every later screen leads with the
    /// state of the job instead.
    private var hero: some View {
        HStack(alignment: .center, spacing: 15) {
            AppIconBadge(size: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text("ThumbPrint")
                    .font(.largeTitle.weight(.semibold))
                Text("Make a backup copy of your DJ drive.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    // MARK: - Mode

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $job.mode) {
                ForEach(CloneMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Held to a minimum height so switching modes doesn't shift every
            // control below it by a line.
            Text(job.mode.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 15, alignment: .top)
        }
    }

    // MARK: - Drives

    /// Which end of the copy a section represents. The two ends offer different
    /// image actions: you can only ever *open* an image to read from, but the
    /// destination can also be a brand new one.
    private enum SectionRole { case from, to }

    private func driveSection(
        title: String,
        systemImage: String,
        selection: Binding<Endpoint?>,
        excluded: Endpoint?,
        isDestination: Bool = false,
        role: SectionRole
    ) -> some View {
        let showsImageRows = job.mode.allowsImageEndpoints

        return VStack(alignment: .leading, spacing: 7) {
            SectionLabel(title, systemImage: systemImage)

            VStack(spacing: 0) {
                ForEach(drives) { drive in
                    let isExcluded = drive.id == excluded?.id
                    let isUnwritable = isDestination && drive.isReadOnly

                    DriveRow(
                        drive: drive,
                        isSelected: selection.wrappedValue?.id == drive.id,
                        disabledReason: isExcluded
                            ? "already selected as the other drive"
                            : (isUnwritable ? "read-only" : nil),
                        history: history(for: drive)
                    ) {
                        selection.wrappedValue = .drive(drive)
                    }

                    if drive.id != drives.last?.id || showsImageRows {
                        // Inset to start under the text, not the icon, so the
                        // rule reads as separating entries rather than columns.
                        Divider().padding(.leading, 52)
                    }
                }

                if showsImageRows {
                    imageRows(selection: selection, role: role)
                }
            }
            .cardEdgeToEdge()
        }
    }

    /// The disk-image entries at the bottom of a drive list.
    ///
    /// Once an image is chosen it replaces the chooser rows, so the list never
    /// shows both "here's your image" and "pick an image" at the same time.
    @ViewBuilder
    private func imageRows(selection: Binding<Endpoint?>, role: SectionRole) -> some View {
        if let url = selection.wrappedValue?.imageURL {
            ImageFileRow(
                title: url.lastPathComponent,
                subtitle: imageSubtitle(for: url),
                isSelected: true
            ) {
                // Tapping the chosen image clears it, so there's a way back to
                // the drives without a separate control.
                selection.wrappedValue = nil
            }
        } else {
            if role == .to, !job.mode.isInspection {
                ImageFileRow(
                    title: "New disk image…",
                    subtitle: "Save this drive to a file you can restore later",
                    systemImage: "plus.rectangle.on.folder",
                    isPlaceholder: true
                ) {
                    chooseNewImage(for: selection)
                }

                Divider().padding(.leading, 52)
            }

            ImageFileRow(
                title: role == .to ? "Existing disk image…" : "Disk image…",
                subtitle: role == .to
                    ? "Update an image you saved before"
                    : "Restore from an image you saved before",
                systemImage: "folder",
                isPlaceholder: true
            ) {
                chooseExistingImage(for: selection)
            }
        }
    }

    /// "on Macintosh HD · 81.2 GB", or just the folder when the file isn't there
    /// yet. Answers the question the filename doesn't: where is this, and how big
    /// has it got.
    private func imageSubtitle(for url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let location = (try? folder.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
            ?? folder.lastPathComponent

        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return "New image on \(location)"
        }
        return "on \(location) · \(ByteFormat.string(size.int64Value))"
    }

    // MARK: - Choosing an image file

    private func chooseNewImage(for selection: Binding<Endpoint?>) {
        let panel = NSSavePanel()
        panel.title = "New Disk Image"
        panel.prompt = "Create"
        panel.message = "Choose where to keep the backup image. It grows only as large as the files you copy."
        panel.nameFieldStringValue = suggestedImageName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(url: normalizedImageURL(url), into: selection)
    }

    private func chooseExistingImage(for selection: Binding<Endpoint?>) {
        let panel = NSOpenPanel()
        panel.title = "Open Disk Image"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: Endpoint.imageFileExtension) {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // A file that isn't a disk image can't become a preflight blocker — a
        // `PreflightReport` needs two live volumes, and this is exactly the case
        // where nothing ever gets attached. Refuse it here instead.
        guard (try? DiskImageStore.info(for: url)) != nil else {
            selectionError = "“\(url.lastPathComponent)” isn't a disk image ThumbPrint can read."
            return
        }

        adopt(url: url, into: selection)
    }

    /// Applies the rules that can be decided from the path alone, before anything
    /// is created or attached.
    private func adopt(url: URL, into selection: Binding<Endpoint?>) {
        let folder = url.deletingLastPathComponent()
        let hostFormat = (try? folder.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]))?
            .volumeLocalizedFormatDescription ?? ""

        if let refusal = ImagePreflight.selectionRefusal(
            imageURL: url,
            hostFormatDescription: hostFormat,
            mountedVolumes: drives.map { .init(name: $0.name, path: $0.volumeURL.path) }
        ) {
            selectionError = refusal
            return
        }

        if let open = DiskImageStore.attachment(for: url), open.mountPoint != nil {
            selectionError = "“\(url.lastPathComponent)” is already open. Eject it in Finder, then choose it again."
            return
        }

        selection.wrappedValue = .image(url)
    }

    /// `NSSavePanel` will happily hand back a name with no extension, or one the
    /// user typed themselves.
    private func normalizedImageURL(_ url: URL) -> URL {
        url.pathExtension.lowercased() == Endpoint.imageFileExtension
            ? url
            : url.appendingPathExtension(Endpoint.imageFileExtension)
    }

    private var suggestedImageName: String {
        let base = job.source?.displayName ?? "ThumbPrint Backup"
        return "\(base).\(Endpoint.imageFileExtension)"
    }

    /// What ThumbPrint remembers about this drive, in one line.
    ///
    /// `nil` for a drive with no recorded copy — including one seen before but
    /// never used. "Seen once, never backed up" is noise on a row the user is
    /// about to select anyway, and five drives each captioned with a non-fact is
    /// worse than five drives with none.
    private func history(for drive: Drive) -> String? {
        guard let sync = registry.record(for: drive)?.lastSync else { return nil }

        let when = AgeFormat.ago(sync.finishedAt)
        let subject = switch sync.role {
        case .source: "Backed up to \(sync.otherDriveName)"
        case .backup: "Copy of \(sync.otherDriveName)"
        }

        // An unverified run is reported as attempted, not as done. Saying
        // "backed up" about a copy that skipped files would be the app
        // reassuring someone on the strength of nothing.
        return sync.verified ? "\(subject) · \(when)" : "\(subject) · \(when) · unverified"
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Text("No USB drives connected")
                .font(.headline)

            Text("Plug in the drive you want to copy and the drive you want to copy it to. ThumbPrint only ever shows removable drives — your Mac's disk can't be selected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .card()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if job.mode == .exactClone {
                Label("Requires an administrator password", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if job.mode.isInspection {
                Label("Nothing will be written to either drive", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(job.mode.isInspection ? "Compare" : "Continue") {
                job.analyze()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!job.canAnalyze)
            .controlSize(.large)
        }
    }
}

// MARK: - Row

private struct DriveRow: View {
    let drive: Drive
    let isSelected: Bool
    let disabledReason: String?
    let history: String?
    let action: () -> Void

    @State private var isHovering = false

    private var isDisabled: Bool { disabledReason != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                icon

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(drive.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        formatBadge
                    }

                    Text(capacityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)

                    CapacityBar(
                        used: drive.usedCapacity,
                        total: drive.totalCapacity,
                        tint: isSelected ? .accentColor : .secondary
                    )
                    .frame(maxWidth: 260)

                    // Below the bar rather than beside the name: it answers
                    // "which of these identical sticks is this" — useful, but
                    // never more useful than the drive's name and size.
                    if let history {
                        Label(history, systemImage: "clock.arrow.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(minHeight: Metrics.minHitHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .background(rowBackground)
        .opacity(isDisabled ? 0.42 : 1)
        .disabled(isDisabled)
        .onHover { hovering in
            guard !isDisabled else { return }
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .help(disabledReason.map { "Unavailable — \($0)" } ?? drive.volumeURL.path)
    }

    private var icon: some View {
        Image(systemName: isSelected ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
            .font(.system(size: 21))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 26)
    }

    private var formatBadge: some View {
        Text(drive.formatDescription)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.13)
        } else if isHovering {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }

    private var capacityText: String {
        var text = "\(ByteFormat.string(drive.usedCapacity)) of \(ByteFormat.string(drive.totalCapacity)) used"
        if let disabledReason {
            text += " · \(disabledReason)"
        }
        return text
    }
}
