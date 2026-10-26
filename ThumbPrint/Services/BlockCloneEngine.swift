import Foundation

/// Bit-for-bit raw device clone of one whole disk onto another.
///
/// Raw device access requires root, so the actual copy runs in a short shell
/// script executed through the standard macOS admin prompt. A `SMJobBless`
/// privileged helper would be the heavyweight alternative, but it requires a
/// paid Developer ID and buys nothing for a locally-built personal tool.
final class BlockCloneEngine {
    struct Result {
        var bytesCopied: Int64 = 0
        var diskSize: Int64 = 0
    }

    private let onProgress: (CloneProgress) -> Void
    private var progress = CloneProgress()
    private var meter = ThroughputMeter()

    init(onProgress: @escaping (CloneProgress) -> Void) {
        self.onProgress = onProgress
    }

    // MARK: - Entry point

    func run(source: Drive, target: Drive) throws -> Result {
        guard let sourceRaw = source.rawDevicePath,
              let targetRaw = target.rawDevicePath,
              let sourceBSD = source.wholeDiskBSDName,
              let targetBSD = target.wholeDiskBSDName
        else {
            throw CloneError.exactCloneUnavailable
        }

        // The BSD names above were read at preflight, and macOS reuses them: swap
        // the backup stick while the preflight screen is up and the new one can
        // come back as the same `disk4`. A raw clone onto the wrong disk is the
        // worst thing this app could do, so both drives are re-read and must
        // still be the same volume on the same disk before anything is unmounted.
        for drive in [target, source] {
            guard drive.isSameDisk(as: DriveFormatter.currentDrive(atVolumePath: drive.volumeURL.path)) else {
                throw CloneError.driveChanged(drive.name)
            }
        }

        let sourceSize = try Self.wholeDiskSize(bsdName: sourceBSD)
        let targetSize = try Self.wholeDiskSize(bsdName: targetBSD)

        // A raw clone writes every block, used or not, so the target must be at
        // least as large as the source disk — not merely as large as its data.
        guard targetSize >= sourceSize else {
            throw CloneError.targetTooSmall(needed: sourceSize, available: targetSize)
        }

        publish {
            $0.stage = .unmounting
            $0.currentItem = "\(source.name) and \(target.name)"
            $0.bytesTotal = sourceSize
            $0.bytesCompleted = 0
        }

        // Registered BEFORE the unmounts, deliberately: if the second unmount
        // fails, the first drive is already unmounted and would otherwise be
        // left that way with no path back. Remounting an already-mounted disk
        // is a harmless no-op.
        defer {
            remountDisk(bsdName: sourceBSD)
            remountDisk(bsdName: targetBSD)
        }

        // A mounted volume can't be raw-written, and reading a mounted source
        // raw would capture a filesystem mid-flight.
        try unmountDisk(bsdName: targetBSD, displayName: target.name)
        try unmountDisk(bsdName: sourceBSD, displayName: source.name)

        publish { $0.stage = .rawCopying; $0.currentItem = "\(source.name) → \(target.name)" }

        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.directory) }

        let bytesCopied = try runPrivilegedCopy(
            from: sourceRaw,
            to: targetRaw,
            totalBytes: sourceSize,
            workspace: workspace
        )

        return Result(bytesCopied: bytesCopied, diskSize: sourceSize)
    }

    // MARK: - Disk geometry

    /// Total size of the physical disk, which is what an Exact Clone must copy.
    /// This is *not* the same as the volume's capacity — the partition map and
    /// any other partitions count too.
    static func wholeDiskSize(bsdName: String) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/dev/\(bsdName)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw CloneError.privilegedTaskFailed(error.localizedDescription)
        }

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let plist = try? PropertyListSerialization.propertyList(
            from: output, options: [], format: nil
        ) as? [String: Any] else {
            throw CloneError.cannotReadVolume(bsdName)
        }

        // `TotalSize` is the modern key; `Size` is the older spelling.
        if let total = plist["TotalSize"] as? NSNumber { return total.int64Value }
        if let size = plist["Size"] as? NSNumber { return size.int64Value }
        throw CloneError.cannotReadVolume(bsdName)
    }

    private func unmountDisk(bsdName: String, displayName: String) throws {
        let status = try runDiscardingOutput("/usr/sbin/diskutil", ["unmountDisk", "/dev/\(bsdName)"])
        guard status == 0 else {
            throw CloneError.unmountFailed(displayName)
        }
    }

    private func remountDisk(bsdName: String) {
        _ = try? runDiscardingOutput("/usr/sbin/diskutil", ["mountDisk", "/dev/\(bsdName)"])
    }

    // MARK: - Privileged copy

    private struct Workspace {
        /// User-owned, 0700. Holds only the cancel flag.
        let directory: URL
        let cancelFlag: URL
        /// Created by the root script itself; see `privilegedScript`.
        let runDirectory: URL
        var progressLog: URL { runDirectory.appendingPathComponent("progress.log") }
    }

    /// Where root keeps its progress log. Only root can create entries here, so
    /// nothing running as the user can put a file — or a symlink — in the way.
    static let privilegedRunRoot = URL(fileURLWithPath: "/var/run", isDirectory: true)

    /// SECURITY: the script runs as root, so **nothing root reads or writes may
    /// live somewhere the user can change.** The script is handed to root inline
    /// rather than as a file, and its log lives in a directory root creates,
    /// because a 0700 user-owned directory stops other users but not a process
    /// already running as this one: it could have swapped the script between
    /// write and run, or replaced `progress.log` with a symlink to a system file
    /// for root's `2>` to overwrite. The cancel flag is the one exception, and
    /// safe: root only tests whether it exists.
    private func makeWorkspace() throws -> Workspace {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thumbprint-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        return Workspace(
            directory: directory,
            cancelFlag: directory.appendingPathComponent("cancel"),
            runDirectory: Self.privilegedRunRoot
                .appendingPathComponent("thumbprint-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func runPrivilegedCopy(
        from sourceRaw: String,
        to targetRaw: String,
        totalBytes: Int64,
        workspace: Workspace
    ) throws -> Int64 {
        let script = Self.privilegedScript(
            source: sourceRaw,
            target: targetRaw,
            runDirectory: workspace.runDirectory,
            cancelFlag: workspace.cancelFlag
        )

        // `do shell script` buffers output and returns only at completion, so
        // stdout can't be streamed. The script therefore reports its own
        // progress into a file that this side tails, and hands back the end of
        // that log on stdout once it has finished and removed it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.appleScript(running: script, privileged: true)]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        do {
            try process.run()
        } catch {
            throw CloneError.privilegedTaskFailed(error.localizedDescription)
        }

        var bytesCopied: Int64 = 0
        var cancelled = false

        while process.isRunning {
            if !cancelled && Task.isCancelled {
                // Signal the script rather than killing osascript, so `dd` gets
                // terminated cleanly and the drives are left in a known state.
                FileManager.default.createFile(atPath: workspace.cancelFlag.path, contents: nil)
                cancelled = true
            }

            if let bytes = readBytesTransferred(from: workspace.progressLog), bytes > bytesCopied {
                let delta = bytes - bytesCopied
                bytesCopied = bytes
                let rate = meter.record(bytes: delta)
                publish {
                    $0.bytesCompleted = bytes
                    $0.bytesTotal = totalBytes
                    $0.bytesPerSecond = rate
                }
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        process.waitUntilExit()

        // The run directory is gone by now; what the script printed is the end
        // of its log. Small by construction (`tail`), so it can't have filled
        // the pipe while the loop above wasn't reading it.
        let finalLog = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        if let bytes = Self.bytesTransferred(in: finalLog) {
            bytesCopied = max(bytesCopied, bytes)
        }

        if cancelled { throw CancellationError() }

        let errorText = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        if process.terminationStatus != 0 {
            // -128 is AppleScript's "user cancelled" for the auth prompt.
            if errorText.contains("-128") || errorText.localizedCaseInsensitiveContains("user canceled") {
                throw CloneError.authorizationCancelled
            }
            throw CloneError.rawCopyFailed(
                exitCode: process.terminationStatus,
                message: Self.ddDiagnostics(in: finalLog, fallback: errorText)
            )
        }

        // The script always exits 0 and reports dd's status in its log, so a
        // run that printed no status didn't get as far as dd finishing.
        guard let scriptExit = Self.scriptExitCode(in: finalLog) else {
            throw CloneError.rawCopyFailed(
                exitCode: -1,
                message: "The clone helper ended without reporting a result."
            )
        }
        if scriptExit != 0 {
            throw CloneError.rawCopyFailed(
                exitCode: scriptExit,
                message: Self.ddDiagnostics(in: finalLog, fallback: "")
            )
        }

        return bytesCopied
    }

    /// The script root runs. Static and parameterized by directory so
    /// `Tests/run.sh` can run it unprivileged against two plain files.
    ///
    /// It always exits 0 and reports dd's status as `thumbprint-exit:N` on
    /// stdout, because `do shell script` throws away stdout when the shell exits
    /// non-zero — and stdout is the only way the end of the log gets back once
    /// the run directory has been removed.
    static func privilegedScript(
        source: String,
        target: String,
        runDirectory: URL,
        cancelFlag: URL
    ) -> String {
        // BSD dd has no `status=progress`, but it does dump a transfer count to
        // stderr on SIGINFO. Both the loop and dd run as root here, so the
        // signal goes through.
        """
        SRC=\(shellQuoted(source))
        DST=\(shellQuoted(target))
        RUN=\(shellQuoted(runDirectory.path))
        CANCEL=\(shellQuoted(cancelFlag.path))

        # mkdir fails if anything already exists at RUN, so the log below is
        # always a fresh file in a directory only root can write to.
        if ! mkdir -m 755 "$RUN"; then
            echo "Couldn't create the clone helper's working folder."
            echo "thumbprint-exit:70"
            exit 0
        fi
        PROGRESS="$RUN/progress.log"

        finish() {
            echo "thumbprint-exit:$1" >> "$PROGRESS"
            tail -n 20 "$PROGRESS"
            rm -rf "$RUN"
            exit 0
        }

        # Cancel may have been pressed while the password prompt was up. Checked
        # before dd starts, because a dd killed a second in has already
        # overwritten the target's partition map.
        if [ -f "$CANCEL" ]; then
            finish 130
        fi

        dd if="$SRC" of="$DST" bs=8m 2>"$PROGRESS" &
        pid=$!

        while kill -0 "$pid" 2>/dev/null; do
            if [ -f "$CANCEL" ]; then
                kill "$pid" 2>/dev/null
                break
            fi
            kill -s INFO "$pid" 2>/dev/null || kill -29 "$pid" 2>/dev/null
            sleep 1
        done

        wait "$pid"
        finish $?
        """
    }

    /// `do shell script` with the script passed inline to `/bin/sh -c`. Without
    /// `without altering line endings` the result comes back with CRs, which
    /// the log parsing below would not split on.
    static func appleScript(running script: String, privileged: Bool) -> String {
        let command = "/bin/sh -c \(shellQuoted(script))"
        return "do shell script \(appleScriptQuoted(command))"
            + (privileged ? " with administrator privileges" : "")
            + " without altering line endings"
    }

    // MARK: - Progress parsing

    private func readBytesTransferred(from log: URL) -> Int64? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        return Self.bytesTransferred(in: text)
    }

    static func bytesTransferred(in text: String) -> Int64? {
        // dd emits e.g. "10485760 bytes transferred in 1.234567 secs (…)".
        var latest: Int64?
        for line in text.components(separatedBy: .newlines) {
            guard let range = line.range(of: " bytes transferred") else { continue }
            let number = line[line.startIndex..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if let value = Int64(number) { latest = value }
        }
        return latest
    }

    static func scriptExitCode(in text: String) -> Int32? {
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("thumbprint-exit:") {
            return Int32(line.replacingOccurrences(of: "thumbprint-exit:", with: "").trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func ddDiagnostics(in text: String, fallback: String) -> String {
        let interesting = text
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("thumbprint-exit:") && !$0.contains("records") }
            .suffix(3)
            .joined(separator: "\n")
        return interesting.isEmpty ? fallback : interesting
    }

    // MARK: - Subprocess helpers

    private func runCapturing(_ launchPath: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw CloneError.privilegedTaskFailed(error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    @discardableResult
    private func runDiscardingOutput(_ launchPath: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw CloneError.privilegedTaskFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Quoting

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The script is multi-line now that it travels inline, so newlines are
    /// escaped too; AppleScript turns `\n` back into a linefeed.
    private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func publish(_ mutate: (inout CloneProgress) -> Void) {
        mutate(&progress)
        onProgress(progress)
    }
}
