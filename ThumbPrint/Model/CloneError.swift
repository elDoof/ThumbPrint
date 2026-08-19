import Foundation

enum CloneError: LocalizedError {
    case cannotReadVolume(String)
    case sourceDisappeared(String)
    case targetDisappeared(String)
    case targetReadOnly(String)
    case outOfSpace(needed: Int64, available: Int64)
    case exactCloneUnavailable
    case targetTooSmall(needed: Int64, available: Int64)
    case unmountFailed(String)
    case authorizationCancelled
    case privilegedTaskFailed(String)
    case rawCopyFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .cannotReadVolume(let name):
            return "Couldn't read “\(name)”. Check that the drive is still connected and that ThumbPrint has permission to access removable volumes."

        case .sourceDisappeared(let name):
            return "The source drive “\(name)” was disconnected before the copy finished."

        case .targetDisappeared(let name):
            return "The backup drive “\(name)” was disconnected before the copy finished. Its contents are incomplete — run the backup again."

        case .targetReadOnly(let name):
            return "“\(name)” is read-only and can't be used as a backup drive."

        case .outOfSpace(let needed, let available):
            return "Not enough free space on the backup drive. Needs \(ByteFormat.string(needed)), has \(ByteFormat.string(available))."

        case .exactCloneUnavailable:
            return "Exact Clone isn't available for this drive — macOS didn't report a disk device for it. Fast Sync will still work."

        case .targetTooSmall(let needed, let available):
            return "Exact Clone copies every block on the disk, so the backup drive must be at least as large as the source. Needs \(ByteFormat.string(needed)), is \(ByteFormat.string(available))."

        case .unmountFailed(let name):
            return "Couldn't unmount “\(name)”. Close any apps using the drive (including Finder windows) and try again."

        case .authorizationCancelled:
            return "Administrator permission is required for an Exact Clone."

        case .privilegedTaskFailed(let message):
            return "The clone helper failed to start: \(message)"

        case .rawCopyFailed(let exitCode, let message):
            let detail = message.isEmpty ? "" : "\n\n\(message)"
            return "The disk copy failed (exit code \(exitCode)).\(detail)"
        }
    }
}
