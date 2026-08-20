import AppKit
import Foundation

/// Owns the update feature's state: when to check, what was found, and what the
/// user chose to do about it.
///
/// The split is the same one `DriveRegistry`/`DriveRegistryStore` uses — every
/// rule worth pinning lives in `UpdateRelease`, `AppVersion` and
/// `UpdateInstaller`, which the harness compiles; this class only adds main-actor
/// isolation, the once-a-day timer and the "skip this version" memory.
///
/// The one thing it must never do is get in the way. An update prompt appearing
/// over a running backup would be the app interrupting the only job it has, so
/// the automatic check is silent unless there is something to say, and
/// `ContentView` holds the sheet back while a copy is in flight.
@MainActor
@Observable
final class UpdateController {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        /// Downloading, verifying, or swapping the bundle. The string is what to
        /// show; the steps are too fast to be worth separate cases.
        case working(String)
        /// Installed and about to relaunch.
        case installed(UpdateRelease)
        /// Verified but not installable here — left in ~/Downloads instead.
        case downloaded(path: String, reason: String)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Whether the update sheet wants to be on screen. `ContentView` decides when
    /// it actually appears.
    private(set) var isPresenting = false

    /// At most one automatic check a day. A manual check ignores this entirely.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private enum Key {
        static let lastCheck = "UpdateCheck.lastRun"
        static let skippedVersion = "UpdateCheck.skippedVersion"
    }

    private let defaults: UserDefaults
    private let bundle: Bundle
    private var inFlight: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
    }

    var currentVersion: AppVersion? { AppVersion.current(in: bundle) }

    var isBusy: Bool {
        switch state {
        case .checking, .working: return true
        default: return false
        }
    }

    // MARK: - Checking

    /// The launch check. Silent in every outcome except "there's a newer one you
    /// haven't already skipped".
    ///
    /// Failures are swallowed on purpose. A Mac that is offline, behind a
    /// captive portal, or hitting GitHub's rate limit is not a situation the user
    /// asked to hear about — they opened a backup tool.
    func checkOnLaunch() {
        guard currentVersion != nil else { return }

        if let last = defaults.object(forKey: Key.lastCheck) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }

        run(announcing: false)
    }

    /// The menu item. Says something whatever the answer is, including "you're up
    /// to date" and including the reason it couldn't tell.
    func checkNow() {
        run(announcing: true)
    }

    private func run(announcing: Bool) {
        guard inFlight == nil else { return }

        if announcing {
            state = .checking
            isPresenting = true
        }

        inFlight = Task { [weak self] in
            defer { self?.inFlight = nil }
            do {
                let release = try await UpdateInstaller.fetchLatest()
                guard let self else { return }

                self.defaults.set(Date(), forKey: Key.lastCheck)

                guard release.isNewer(than: self.currentVersion) else {
                    if announcing {
                        self.state = .upToDate
                    }
                    return
                }

                // A version the user said no to stays said-no-to until a newer
                // one appears. An automatic check that re-asked every day would
                // be nagging; a manual check is the user asking, so it shows it.
                if !announcing, self.isSkipped(release) { return }

                self.state = .available(release)
                self.isPresenting = true
            } catch {
                guard let self else { return }
                if announcing {
                    self.state = .failed(error.localizedDescription)
                } else {
                    // Not shown, but the timestamp is still recorded: a failed
                    // check shouldn't mean retrying on every launch.
                    self.defaults.set(Date(), forKey: Key.lastCheck)
                }
            }
        }
    }

    // MARK: - Installing

    func install() {
        guard case .available(let release) = state, inFlight == nil else { return }

        let bundleURL = bundle.bundleURL
        state = .working("Downloading \(release.assetName)…")

        inFlight = Task { [weak self] in
            defer { self?.inFlight = nil }
            do {
                let dmg = try await UpdateInstaller.download(release)
                guard let self else { return }

                switch UpdateInstaller.destination(for: bundleURL) {
                case .replace(let target):
                    self.state = .working("Verifying the download…")
                    // Off the main actor: this runs codesign, spctl, hdiutil and
                    // ditto, and the window has to keep drawing while it does.
                    try await Task.detached(priority: .userInitiated) {
                        try UpdateInstaller.install(
                            downloadedImage: dmg,
                            release: release,
                            replacing: target
                        )
                    }.value

                    self.state = .installed(release)
                    UpdateInstaller.scheduleRelaunch(of: target)
                    // Long enough for the sheet to say what happened, short
                    // enough not to look stuck.
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    NSApplication.shared.terminate(nil)

                case .revealOnly(let reason):
                    let moved = try UpdateInstaller.moveToDownloads(dmg)
                    try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent())
                    self.state = .downloaded(path: moved.path, reason: reason)
                }
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Dismissal

    func skipCurrentRelease() {
        if case .available(let release) = state {
            defaults.set(release.tag, forKey: Key.skippedVersion)
        }
        dismiss()
    }

    func dismiss() {
        guard !isBusy else { return }
        isPresenting = false
        state = .idle
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(UpdateInstaller.releasesPageURL)
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func isSkipped(_ release: UpdateRelease) -> Bool {
        guard let skipped = defaults.string(forKey: Key.skippedVersion),
              let skippedVersion = AppVersion(skipped)
        else { return false }
        // Only *this* version is skipped. Anything newer is offered again.
        return release.version <= skippedVersion
    }
}
