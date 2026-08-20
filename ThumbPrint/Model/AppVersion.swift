import Foundation

/// A dotted release version — `1.0`, `1.2.3`, `v2.0` — comparable against
/// another one.
///
/// Its own type rather than a string compare because string ordering puts
/// "1.10" before "1.9", which is exactly the case an update check gets wrong
/// once and then never gets a chance to correct: the app would decide it was
/// already up to date and stop offering the newer build.
///
/// Pure, and in `Model/` rather than the updater service, so `Tests/run.sh`
/// pins the comparison without a network.
struct AppVersion: Comparable, CustomStringConvertible, Equatable {
    /// Numeric components, most significant first. Never empty.
    let components: [Int]

    /// Exactly what was parsed, for display. `1.0` stays `1.0`, not `1.0.0`.
    let raw: String

    /// Accepts an optional leading `v`, ignores anything from the first
    /// non-numeric component onward (`1.2-beta` reads as `1.2`), and fails on a
    /// string with no leading number at all.
    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed
        if let first = body.first, first == "v" || first == "V" {
            body = String(body.dropFirst())
        }

        var parsed: [Int] = []
        for piece in body.split(separator: ".", omittingEmptySubsequences: false) {
            // "3-beta" contributes 3 and ends the version.
            let digits = piece.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            parsed.append(value)
            if digits.count != piece.count { break }
        }

        guard !parsed.isEmpty else { return nil }
        components = parsed
        raw = trimmed
    }

    var description: String { raw }

    /// Component-wise, with a missing component read as zero — so `1.0` and
    /// `1.0.0` are the same version rather than two.
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// The running build's `CFBundleShortVersionString`.
    ///
    /// `nil` when there isn't one, which is the case in the test harness — a
    /// plain CLI binary has no marketing version. Callers treat that as "can't
    /// tell, so don't offer an update", which is the safe direction.
    static func current(in bundle: Bundle = .main) -> AppVersion? {
        guard let string = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return nil }
        return AppVersion(string)
    }
}
