import SwiftUI

struct ContentView: View {
    /// Owned by the app, not by this view — the menu's "Check for Updates…"
    /// reaches the same instance.
    let updates: UpdateController

    @State private var scanner = DriveScanner()
    @State private var job = CloneJob()

    /// Not `@State`: the registry outlives any view and is shared with `CloneJob`,
    /// which reaches it directly. Observation still tracks the reads in `body`.
    private let registry = DriveRegistry.shared

    var body: some View {
        Group {
            switch job.phase {
            case .idle:
                DrivePickerView(job: job, drives: scanner.drives, registry: registry)

            case .analyzing, .running:
                CloneProgressView(
                    progress: job.progress,
                    sourceName: job.sourceDisplayName,
                    targetName: job.targetDisplayName,
                    onCancel: { job.cancel() }
                )

            case .preflight(let report):
                PreflightView(
                    report: report,
                    onStart: { job.start() },
                    onBack: { job.reset() }
                )

            case .comparison(let report):
                ComparisonView(report: report, onDone: { job.reset() })

            case .finished(let summary):
                SummaryView(outcome: .finished(summary), onDone: { job.reset() })

            case .failed(let message):
                SummaryView(
                    outcome: .failed(message),
                    onDone: { job.reset() },
                    targetWarning: job.targetWarning
                )

            case .cancelled:
                SummaryView(
                    outcome: .cancelled,
                    onDone: { job.reset() },
                    targetWarning: job.targetWarning
                )
            }
        }
        // Phases are separate screens in the same window, so they cross-fade
        // rather than hard-cut. Enter carries a small upward drift; exit is a
        // plain fade, so backing out feels quieter than moving forward.
        //
        // The `id` is what makes the transition fire at all: without a change
        // of identity SwiftUI reuses the view and animates nothing. It's keyed
        // on the phase alone, so the running screen isn't rebuilt on every
        // progress tick.
        .id(phaseID)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)),
                removal: .opacity
            )
        )
        .animation(.easeOut(duration: 0.22), value: phaseID)
        .sheet(isPresented: presentingUpdate) {
            UpdateSheet(controller: updates)
        }
        .task {
            // If the app was killed while a disk image was open, the mount
            // survives the process — invisible in Finder, and enough to make the
            // *same* image fail to attach next time with a confusing "resource
            // busy". This is the backstop for the one exit path no `defer` can
            // cover. Off the main actor: it shells out to `hdiutil`.
            let reap = Task.detached(priority: .utility) {
                _ = DiskImageStore.reapStaleMounts()
            }
            await reap.value

            // Silent unless there's a newer version, and at most once a day.
            // Deliberately after the reap: a stale mount is the app's own mess
            // to clean up before it starts talking about anything else.
            updates.checkOnLaunch()
        }
        .onChange(of: scanner.drives) { _, drives in
            // Every sighting, regardless of phase: this is how a drive that is
            // only ever a backup target still accumulates a history.
            registry.noteSeen(drives)

            // Only meaningful while idle — mid-clone the engines detect a
            // disconnect themselves and fail with a specific error.
            if case .idle = job.phase {
                job.dropMissingDrives(available: drives)
            }
        }
    }

    /// The update sheet waits for the app to be doing nothing.
    ///
    /// An update prompt appearing over a running backup would be this app
    /// interrupting the only job it has. The controller decides *whether* there
    /// is something to say; this decides *when* it may be said.
    private var presentingUpdate: Binding<Bool> {
        Binding(
            get: { updates.isPresenting && !job.isBusy },
            set: { if !$0 { updates.dismiss() } }
        )
    }

    /// Identity of the current phase, ignoring its payload. `Phase` carries
    /// reports and summaries that change as work proceeds; keying the screen
    /// transition on those would rebuild the view mid-copy.
    private var phaseID: Int {
        switch job.phase {
        case .idle: return 0
        case .analyzing: return 1
        case .preflight: return 2
        case .running: return 3
        case .finished: return 4
        case .failed: return 5
        case .cancelled: return 6
        case .comparison: return 7
        }
    }
}
