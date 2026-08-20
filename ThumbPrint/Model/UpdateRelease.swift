import Foundation

/// A published ThumbPrint release, as GitHub describes it.
///
/// Parsing lives in a pure value type for the same reason `ImagePreflight` does:
/// the network call is the uninteresting part, and the decisions worth pinning —
/// is this a real release, which asset is the app, is it actually newer — are all
/// decisions about a blob of JSON. `Tests/run.sh` drives this against fixture
/// text with no network at all.
struct UpdateRelease: Equatable {
    let version: AppVersion
    /// The git tag, e.g. `v1.1`. Kept verbatim for the "skip this version" record.
    let tag: String
    let title: String
    /// The release body, as Markdown. Shown as-is; nothing here renders it.
    let notes: String
    let downloadURL: URL
    let assetName: String
    let assetSize: Int64
    let publishedAt: Date?

    enum ParseFailure: LocalizedError, Equatable {
        case malformedFeed
        case notAPublishedRelease
        case noVersionInTag(String)
        case noDiskImageAsset(String)

        var errorDescription: String? {
            switch self {
            case .malformedFeed:
                return "Couldn't read the update information from GitHub."
            case .notAPublishedRelease:
                return "The latest release on GitHub is a draft or a pre-release."
            case .noVersionInTag(let tag):
                return "The latest release is tagged “\(tag)”, which isn't a version number ThumbPrint can compare."
            case .noDiskImageAsset(let tag):
                return "Release \(tag) has no .dmg attached to download."
            }
        }
    }

    /// Parses one release object from the GitHub REST API
    /// (`/repos/:owner/:repo/releases/latest`).
    ///
    /// Deliberately strict about drafts and pre-releases. `releases/latest`
    /// already excludes both, so seeing one means the endpoint changed under us —
    /// and the right response to "the feed isn't what I thought" is to offer no
    /// update rather than to install whatever came back.
    static func parse(_ data: Data) throws -> UpdateRelease {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseFailure.malformedFeed
        }
        return try parse(object)
    }

    static func parse(_ object: [String: Any]) throws -> UpdateRelease {
        if (object["draft"] as? Bool) == true || (object["prerelease"] as? Bool) == true {
            throw ParseFailure.notAPublishedRelease
        }

        guard let tag = object["tag_name"] as? String, !tag.isEmpty else {
            throw ParseFailure.malformedFeed
        }
        guard let version = AppVersion(tag) else {
            throw ParseFailure.noVersionInTag(tag)
        }

        let assets = (object["assets"] as? [[String: Any]]) ?? []
        guard let asset = diskImageAsset(in: assets, version: version),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString)
        else {
            throw ParseFailure.noDiskImageAsset(tag)
        }

        let name = object["name"] as? String
        return UpdateRelease(
            version: version,
            tag: tag,
            title: (name?.isEmpty == false ? name! : "ThumbPrint \(version)"),
            notes: (object["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            downloadURL: url,
            assetName: (asset["name"] as? String) ?? url.lastPathComponent,
            assetSize: (asset["size"] as? NSNumber)?.int64Value ?? 0,
            publishedAt: (object["published_at"] as? String).flatMap(iso8601)
        )
    }

    /// The `.dmg` to download. A release carrying more than one prefers the asset
    /// whose filename mentions the version, so a stray `ThumbPrint-debug.dmg`
    /// can't win by being first.
    private static func diskImageAsset(in assets: [[String: Any]], version: AppVersion) -> [String: Any]? {
        let images = assets.filter { asset in
            guard let name = asset["name"] as? String else { return false }
            return name.lowercased().hasSuffix(".dmg")
        }
        if let matching = images.first(where: {
            (($0["name"] as? String) ?? "").contains(version.raw.replacingOccurrences(of: "v", with: ""))
        }) {
            return matching
        }
        return images.first
    }

    /// GitHub stamps `published_at` as ISO 8601 with no fractional seconds, the
    /// same shape `DriveRecord` round-trips.
    private static func iso8601(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    // MARK: - The decision

    /// Whether this release should be offered over what's running.
    ///
    /// `currentVersion` is optional because a build with no marketing version —
    /// the test harness, mainly — can't be compared against anything, and the
    /// safe answer there is "offer nothing".
    func isNewer(than currentVersion: AppVersion?) -> Bool {
        guard let currentVersion else { return false }
        return version > currentVersion
    }
}
