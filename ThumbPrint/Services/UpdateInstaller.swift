import Foundation

/// Checks GitHub for a newer ThumbPrint, and — if the download proves it was
/// signed by the same Developer ID as the running app — replaces the app bundle
/// with it.
///
/// **The security boundary of this whole feature is `verify(app:)`.** Everything
/// before it is an untrusted blob fetched over the network from a URL a JSON
/// document named. Nothing is executed, moved into place, or even trusted to be
/// ThumbPrint until `codesign` has confirmed the bundle satisfies a *pinned*
/// requirement: Apple's anchor, this exact bundle identifier, and team
/// `DPLC4BD7ST`. A build signed by anyone else fails that test no matter what
/// the feed said.
///
/// No Sparkle, and that is a considered choice rather than a shortcut. Sparkle
/// would bring an EdDSA appcast, a second signing key to keep safe and a
/// dependency into a project that has none. What it buys over this is delta
/// updates and an installer XPC service, neither of which matters for a 2 MB app
/// that is already notarized and already distributed through one channel.
///
/// Foundation-only and free of stored state, like the other services here, so
/// `Tests/run.sh` can compile it and pin the parts that don't need a network.
enum UpdateInstaller {

    // MARK: - Constants

    /// GitHub's REST endpoint for the newest published release. It already
    /// excludes drafts and pre-releases; `UpdateRelease.parse` re-checks anyway.
    ///
    /// Unauthenticated, which caps this at 60 requests an hour per IP address.
    /// The app checks at most once a day, so that ceiling is only reachable by
    /// hammering the menu item.
    static let feedURL = URL(string: "https://api.github.com/repos/elDoof/ThumbPrint/releases/latest")!

    /// Where the user is sent when an install can't be done in place.
    static let releasesPageURL = URL(string: "https://github.com/elDoof/ThumbPrint/releases/latest")!

    static let bundleIdentifier = "com.saschanowlin.ThumbPrint"
    static let teamIdentifier = "DPLC4BD7ST"

    /// The pinned code requirement every downloaded build must satisfy.
    ///
    /// `anchor apple generic` means the certificate chain ends at Apple's root,
    /// which only a real Developer ID certificate does. The identifier and team
    /// pin it to *this* app from *this* account. Verified 2026-08-19 against the
    /// shipped 1.0: the requirement passes on it and fails on an unrelated Apple
    /// binary, so it discriminates in both directions.
    static var codeRequirement: String {
        "anchor apple generic and identifier \"\(bundleIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    // MARK: - Errors

    enum Failure: LocalizedError, Equatable {
        case network(String)
        case httpStatus(Int)
        case downloadFailed(String)
        case cannotOpenDownload(String)
        case noAppInDownload
        case signatureRejected(String)
        case notNotarized(String)
        case versionMismatch(expected: String, found: String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .network(let detail):
                return "Couldn't reach GitHub to check for updates.\n\n\(detail)"
            case .httpStatus(let code):
                return code == 403
                    ? "GitHub is rate-limiting update checks right now. Try again later."
                    : "GitHub answered the update check with HTTP \(code)."
            case .downloadFailed(let detail):
                return "The update didn't download.\n\n\(detail)"
            case .cannotOpenDownload(let detail):
                return "The downloaded disk image wouldn't open.\n\n\(detail)"
            case .noAppInDownload:
                return "The downloaded disk image doesn't contain ThumbPrint."
            case .signatureRejected(let detail):
                return "The downloaded update isn't signed by the same developer as this copy of ThumbPrint, so it was discarded.\n\n\(detail)"
            case .notNotarized(let detail):
                return "macOS wouldn't accept the downloaded update — it isn't notarized.\n\n\(detail)"
            case .versionMismatch(let expected, let found):
                return "The download claims to be version \(expected) but contains version \(found). It was discarded."
            case .installFailed(let detail):
                return "The update downloaded and verified, but couldn't replace the installed app.\n\n\(detail)"
            }
        }
    }

    // MARK: - Check

    /// Fetches and parses the newest published release.
    ///
    /// No progress reporting and no streaming: the response is a few kilobytes of
    /// JSON.
    static func fetchLatest(session: URLSession = .shared) async throws -> UpdateRelease {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 20
        // GitHub asks for an explicit API version and a User-Agent; without the
        // latter the API answers 403.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ThumbPrint", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.httpStatus(http.statusCode)
        }

        return try UpdateRelease.parse(data)
    }

    // MARK: - Download

    /// Downloads the release's `.dmg` into a private temporary directory.
    ///
    /// Whole-response rather than a streamed download with a progress bar,
    /// deliberately: the asset is about 2 MB. A progress bar for a two-megabyte
    /// file is theatre, and the streaming machinery it needs is real code that
    /// can go wrong.
    ///
    /// The caller owns the returned directory and must remove it — `install`
    /// does, on every path.
    static func download(_ release: UpdateRelease, session: URLSession = .shared) async throws -> URL {
        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 120
        request.setValue("ThumbPrint", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.downloadFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.downloadFailed("The download server answered HTTP \(http.statusCode).")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thumbprint-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let file = directory.appendingPathComponent(release.assetName.isEmpty ? "ThumbPrint.dmg" : release.assetName)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw Failure.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Verify

    /// The three questions that have to be answered before anything is moved.
    ///
    /// 1. Is the signature intact and does it satisfy the pinned requirement —
    ///    Apple anchor, this identifier, this team. This is the one that matters:
    ///    it is what makes a tampered or substituted download unusable.
    /// 2. Does Gatekeeper accept it. The release is notarized and stapled, so
    ///    this passes offline; a build that fails it isn't one we published.
    /// 3. Is it the version the feed promised. A mismatch means the release was
    ///    edited after the feed was read, and the app would report an update it
    ///    didn't install.
    static func verify(app: URL, expecting release: UpdateRelease) throws {
        let signature = run("/usr/bin/codesign", [
            "--verify", "--strict", "--deep",
            "-R=\(codeRequirement)",
            app.path,
        ])
        guard signature.status == 0 else {
            throw Failure.signatureRejected(signature.errorText)
        }

        let assessment = run("/usr/sbin/spctl", ["--assess", "--type", "exec", "--verbose=2", app.path])
        guard assessment.status == 0 else {
            throw Failure.notNotarized(assessment.errorText)
        }

        let plist = app.appendingPathComponent("Contents/Info.plist")
        let found = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist), options: [], format: nil
        ) as? [String: Any])?["CFBundleShortVersionString"] as? String

        guard let found, let foundVersion = AppVersion(found), foundVersion == release.version else {
            throw Failure.versionMismatch(expected: release.version.raw, found: found ?? "unknown")
        }
    }

    // MARK: - Install

    /// Where an update can actually be written.
    enum Destination: Equatable {
        /// Replace this bundle in place. The normal case: `/Applications`.
        case replace(URL)
        /// Can't write there, or it's a build tree. Hand the user the download.
        case revealOnly(String)
    }

    /// Decides whether replacing the running bundle is the right thing to do.
    ///
    /// Two cases are refused. A bundle whose parent directory isn't writable
    /// can't be replaced without asking for a password, and this feature is not
    /// worth a privileged helper. A bundle inside a build tree is refused for a
    /// different reason: silently swapping a developer's freshly compiled debug
    /// build for the public release would be a genuinely confusing thing to do to
    /// someone, and `Scripts/build.sh` runs from exactly there.
    static func destination(for bundle: URL) -> Destination {
        let path = bundle.path
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") {
            return .revealOnly("ThumbPrint is running from a build folder, so it wasn't replaced.")
        }

        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return .revealOnly("ThumbPrint is installed somewhere this app can't write to (\(parent.path)).")
        }

        return .replace(bundle)
    }

    /// Attaches the disk image, verifies the app inside it, and swaps it into
    /// place. The disk image is always detached and the download always removed,
    /// including on failure.
    ///
    /// The staging copy is made *next to* the bundle being replaced so that
    /// `replaceItemAt` is a same-volume exchange rather than a copy — the
    /// existing app survives intact right up to the moment the new one is
    /// complete, so an interrupted update can't leave a half-written app bundle
    /// where ThumbPrint used to be.
    static func install(
        downloadedImage dmg: URL,
        release: UpdateRelease,
        replacing bundle: URL
    ) throws {
        // Only ever removes a directory `download` made. The obvious spelling —
        // "delete the folder the dmg was in" — would delete whatever directory a
        // future caller happened to pass a disk image from.
        defer {
            let directory = dmg.deletingLastPathComponent()
            let isOurs = directory.lastPathComponent.hasPrefix("thumbprint-update-")
                && directory.path.hasPrefix(NSTemporaryDirectory())
            if isOurs { try? FileManager.default.removeItem(at: directory) }
        }

        let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thumbprint-update-mount-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = run("/usr/bin/hdiutil", [
            "attach", dmg.path,
            "-mountpoint", mountPoint.path,
            "-nobrowse", "-noautoopen", "-readonly", "-quiet",
        ])
        guard attach.status == 0 else {
            try? FileManager.default.removeItem(at: mountPoint)
            throw Failure.cannotOpenDownload(attach.errorText)
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let newApp = mountPoint.appendingPathComponent("ThumbPrint.app")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: newApp.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw Failure.noAppInDownload
        }

        // Nothing below this line runs until the download has proved it is ours.
        try verify(app: newApp, expecting: release)

        let parent = bundle.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".ThumbPrint-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let staged = staging.appendingPathComponent("ThumbPrint.app")

            // `ditto` rather than `copyItem`: it preserves the extended
            // attributes and resource forks a signed bundle depends on, and a
            // copy that quietly drops one produces an app that fails its own
            // signature check on first launch.
            let copy = run("/usr/bin/ditto", [newApp.path, staged.path])
            guard copy.status == 0 else {
                throw Failure.installFailed(copy.errorText)
            }

            _ = try FileManager.default.replaceItemAt(
                bundle,
                withItemAt: staged,
                backupItemName: nil,
                options: []
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.installFailed(error.localizedDescription)
        }
    }

    /// Relaunches the app once this process has exited.
    ///
    /// The wait matters: `open` on a bundle whose old process is still running
    /// activates the old process instead of starting the new one, so the user
    /// would be looking at the version they just replaced. Polling the PID and
    /// then opening is the one form that works without a helper tool.
    static func scheduleRelaunch(of bundle: URL) {
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        /usr/bin/open \(shellQuoted(bundle.path))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
    }

    /// Moves a verified-but-uninstallable download into ~/Downloads so the user
    /// can install it by hand.
    ///
    /// The fallback for `Destination.revealOnly`. Nothing is verified on this
    /// path — the app isn't being replaced, so the signature check that matters
    /// is the one Gatekeeper performs when the user opens the image themselves,
    /// exactly as it would for a download from the website.
    @discardableResult
    static func moveToDownloads(_ dmg: URL) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

        var destination = downloads.appendingPathComponent(dmg.lastPathComponent)
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = dmg.deletingPathExtension().lastPathComponent
            destination = downloads.appendingPathComponent("\(base) \(suffix).\(dmg.pathExtension)")
            suffix += 1
        }

        try FileManager.default.moveItem(at: dmg, to: destination)
        return destination
    }

    // MARK: - Subprocess

    private struct CommandResult {
        let status: Int32
        let output: Data
        let errorText: String
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: Data(), errorText: error.localizedDescription)
        }

        let output = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // codesign and spctl report their verdicts on stderr, so a bare stdout
        // read would hand the user an empty explanation for a refusal.
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let outputText = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return CommandResult(
            status: process.terminationStatus,
            output: output,
            errorText: errorText.isEmpty ? outputText : errorText
        )
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
