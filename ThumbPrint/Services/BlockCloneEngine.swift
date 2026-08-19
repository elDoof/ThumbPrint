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
        let directory: URL
        let script: URL
        let progressLog: URL
        let cancelFlag: URL
    }

    /// Creates a private, user-only directory for the helper script.
    ///
    /// SECURITY: the script here is executed as root, so its directory is 0700
    /// and the script itself 0500. Never relax these, and never place it
    /// somewhere world-writable such as /tmp — a writable path would let
    /// another local process swap the script's contents between creation and
    /// execution and get root.
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
            script: directory.appendingPathComponent("clone.sh"),
            progressLog: directory.appendingPathComponent("progress.log"),
            cancelFlag: directory.appendingPathComponent("cancel")
        )
    }

    private func runPrivilegedCopy(
        from sourceRaw: String,
        to targetRaw: String,
        totalBytes: Int64,
        workspace: Workspace
    ) throws -> Int64 {
        try writeScript(from: sourceRaw, to: targetRaw, workspace: workspace)

        // `do shell script` buffers output and returns only at completion, so
        // stdout can't be streamed. The script therefore reports its own
        // progress into a file that this side tails.
        let command = "/bin/sh \(shellQuoted(workspace.script.path))"
        let appleScript = "do shell script \(appleScriptQuoted(command)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

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

        if let bytes = readBytesTransferred(from: workspace.progressLog) {
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
                message: ddDiagnostics(from: workspace.progressLog, fallback: errorText)
            )
        }

        if let scriptExit = readScriptExitCode(from: workspace.progressLog), scriptExit != 0 {
            throw CloneError.rawCopyFailed(
                exitCode: scriptExit,
                message: ddDiagnostics(from: workspace.progressLog, fallback: "")
            )
        }

        return bytesCopied
    }

    private func writeScript(from sourceRaw: String, to targetRaw: String, workspace: Workspace) throws {
        // BSD dd has no `status=progress`, but it does dump a transfer count to
        // stderr on SIGINFO. Both the loop and dd run as root here, so the
        // signal goes through.
        let script = """
        #!/bin/sh
        SRC=\(shellQuoted(sourceRaw))
        DST=\(shellQuoted(targetRaw))
        PROGRESS=\(shellQuoted(workspace.progressLog.path))
        CANCEL=\(shellQuoted(workspace.cancelFlag.path))

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
        status=$?
        echo "thumbprint-exit:$status" >> "$PROGRESS"
        exit $status
        """

        try script.write(to: workspace.script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: workspace.script.path
        )
    }

    // MARK: - Progress parsing

    private func readBytesTransferred(from log: URL) -> Int64? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }

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

    private func readScriptExitCode(from log: URL) -> Int32? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("thumbprint-exit:") {
            return Int32(line.replacingOccurrences(of: "thumbprint-exit:", with: "").trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func ddDiagnostics(from log: URL, fallback: String) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return fallback }
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

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func publish(_ mutate: (inout CloneProgress) -> Void) {
        mutate(&progress)
        onProgress(progress)
    }
}
