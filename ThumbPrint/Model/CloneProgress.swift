import Foundation

struct CloneProgress {
    enum Stage: Equatable {
        case preparing
        case preparingImage
        case indexingSource
        case indexingTarget
        case checkingSource
        case deleting
        case creatingFolders
        case copying
        case unmounting
        case rawCopying
        case verifying

        var label: String {
            switch self {
            case .preparing: return "Preparing…"
            case .preparingImage: return "Opening the disk image…"
            case .indexingSource: return "Reading source drive…"
            case .indexingTarget: return "Reading backup drive…"
            case .checkingSource: return "Checking the source drive for damage…"
            case .deleting: return "Removing files no longer on the source…"
            case .creatingFolders: return "Creating folders…"
            case .copying: return "Copying…"
            case .unmounting: return "Unmounting drives…"
            case .rawCopying: return "Cloning disk…"
            case .verifying: return "Verifying…"
            }
        }

        /// Indexing and unmounting have no meaningful denominator, so the UI
        /// shows an indeterminate bar rather than a fake percentage.
        ///
        /// `preparingImage` joins them because `hdiutil` reports nothing while it
        /// works, and formatting a large FAT32 image is not instant — the FAT
        /// tables scale with volume size, so a big one writes real megabytes
        /// before a single file is copied.
        var isDeterminate: Bool {
            switch self {
            case .preparing, .preparingImage, .indexingSource, .indexingTarget, .checkingSource, .unmounting:
                return false
            case .deleting, .creatingFolders, .copying, .rawCopying, .verifying:
                return true
            }
        }
    }

    var stage: Stage = .preparing
    var bytesCompleted: Int64 = 0
    var bytesTotal: Int64 = 0
    var itemsCompleted: Int = 0
    var itemsTotal: Int = 0
    var currentItem: String = ""
    var bytesPerSecond: Double = 0

    var fractionCompleted: Double {
        if bytesTotal > 0 {
            return min(1, max(0, Double(bytesCompleted) / Double(bytesTotal)))
        }
        if itemsTotal > 0 {
            return min(1, max(0, Double(itemsCompleted) / Double(itemsTotal)))
        }
        return 0
    }

    var bytesRemaining: Int64 { max(0, bytesTotal - bytesCompleted) }

    var estimatedTimeRemaining: String? {
        DurationFormat.estimate(bytesRemaining: bytesRemaining, bytesPerSecond: bytesPerSecond)
    }
}

/// Smooths instantaneous throughput so the on-screen rate and ETA don't jump
/// around with every chunk. USB write speed is genuinely bursty — especially on
/// flash drives with small SLC caches — so the raw number is close to useless.
struct ThroughputMeter {
    private var smoothed: Double = 0
    private var lastSample: Date?
    private let smoothingFactor = 0.15

    mutating func record(bytes: Int64, now: Date = Date()) -> Double {
        defer { lastSample = now }
        guard let lastSample else { return smoothed }

        let elapsed = now.timeIntervalSince(lastSample)
        guard elapsed > 0.001 else { return smoothed }

        let instantaneous = Double(bytes) / elapsed
        smoothed = smoothed == 0
            ? instantaneous
            : smoothed + smoothingFactor * (instantaneous - smoothed)
        return smoothed
    }
}
