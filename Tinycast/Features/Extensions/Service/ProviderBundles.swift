import Foundation

/// Where root-search provider bundles live: one `<id>.provider.js` per provider, and the file's name is
/// the id the app keys that provider's support and cache directories by. Scanned rather than listed, so
/// adding a provider is dropping a file in rather than editing the app.
///
/// A development tree is the only source today — `~/code/tinycast-<source>/build/`, a sibling of this
/// repo — which is why the listing is a convention rather than a preference. When a provider can be
/// installed, that directory becomes the fallback and the installed copy wins.
enum ProviderBundles {
    struct Bundle: Equatable {
        let id: String
        let url: URL
    }

    /// Every bundle found, sorted by id so a palette's providers don't reshuffle between launches.
    static var all: [Bundle] {
        searchRoots
            .flatMap { root in
                ((try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil)) ?? [])
            }
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .map { Bundle(id: String($0.lastPathComponent.dropLast(suffix.count)), url: $0) }
            .sorted { $0.id < $1.id }
    }

    private static let suffix = ".provider.js"

    /// The sibling checkouts that hold a provider, by convention: `tinycast-<source>` beside this one.
    private static var searchRoots: [URL] {
        let code = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code")
        let siblings =
            (try? FileManager.default.contentsOfDirectory(at: code, includingPropertiesForKeys: nil))
            ?? []
        return siblings
            .filter { $0.lastPathComponent.hasPrefix("tinycast-") }
            .map { $0.appendingPathComponent("build", isDirectory: true) }
    }
}
