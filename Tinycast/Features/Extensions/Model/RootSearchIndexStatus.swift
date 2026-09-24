import Foundation

/// When a root-search provider's index last updated, read back from the manifest the provider cached.
///
/// The provider downloads the release manifest beside the index it installs, so this reports what is on
/// disk rather than what the release says today — a distinction that only shows up when a sync has been
/// failing, which is exactly when someone looks.
struct RootSearchIndexStatus: Sendable, Equatable {
    var publishedAt: Date

    /// `nil` until the provider has completed a first sync: the manifest is written after the files it
    /// describes, so its absence means nothing is installed yet rather than something went wrong.
    static func read(
        fromCache directory: URL, fileManager: FileManager = .default
    ) -> RootSearchIndexStatus? {
        let path = directory.appendingPathComponent("manifest.json")
        guard let data = fileManager.contents(atPath: path.path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stamp = object["generatedAt"] as? String,
            // Node's `toISOString` always carries milliseconds, which the fractionless style rejects.
            let publishedAt = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp)
        else { return nil }
        return RootSearchIndexStatus(publishedAt: publishedAt)
    }
}
