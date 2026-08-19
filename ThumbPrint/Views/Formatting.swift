import Foundation

enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        // Include bytes so a handful of small files doesn't read as "0 KB"
        // next to a claim that they're about to be deleted.
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: max(0, bytes))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return "\(string(Int64(bytesPerSecond)))/s"
    }
}

/// The gap between two dates, phrased to drop into a sentence ("3 days",
/// "6 hours"). Coarse on purpose and separate from `DurationFormat`: that one
/// measures how long a job took, where seconds matter. Here the useful fact is
/// "long after", so a single unit says it better than three.
enum AgeFormat {
    private static let formatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 1
        return f
    }()

    static func gap(from earlier: Date, to later: Date) -> String {
        let seconds = later.timeIntervalSince(earlier)
        guard seconds.isFinite, seconds > 0 else { return "moments" }
        return formatter.string(from: seconds) ?? "some time"
    }

    /// How long ago something happened ("3 days ago"). Anything under a minute
    /// reads as "just now" — "0 minutes ago" is a worse answer than a vaguer one.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite, seconds >= 60 else { return "just now" }
        return "\(gap(from: date, to: now)) ago"
    }
}

enum DurationFormat {
    private static let formatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "less than a second" }
        return formatter.string(from: seconds) ?? "—"
    }

    /// Estimates remaining time, returning `nil` while throughput is still too
    /// noisy to be worth showing. A wildly wrong ETA is worse than none.
    static func estimate(bytesRemaining: Int64, bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 0, bytesRemaining > 0 else { return nil }
        let seconds = Double(bytesRemaining) / bytesPerSecond
        guard seconds.isFinite, seconds < 60 * 60 * 24 else { return nil }
        return string(seconds)
    }
}
