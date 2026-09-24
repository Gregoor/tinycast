import Foundation

/// Which ratings a root-search provider shows on its result rows — the preference the app writes and
/// the provider reads back from its own cache.
///
/// The provider owns the file's meaning and falls back per key, so a write replaces only `ratings`
/// and leaves anything else in the file alone. A file that says something these choices don't say is
/// reported as `custom` rather than quietly rewritten to one of them.
struct RootSearchRatingsPreference: Sendable, Equatable {
    enum Choice: String, CaseIterable, Sendable {
        case rottenTomatoes
        case rottenTomatoesAndMetacritic
        case imdbOnly
        case custom

        var title: String {
            switch self {
            case .rottenTomatoes: "Rotten Tomatoes"
            case .rottenTomatoesAndMetacritic: "RT and Metacritic"
            case .imdbOnly: "IMDb only"
            case .custom: "Edited by hand"
            }
        }

        var detail: String {
            switch self {
            case .rottenTomatoes: "The tomato where there is one, the star otherwise."
            case .rottenTomatoesAndMetacritic: "Both film scores, the star otherwise."
            case .imdbOnly: "The star for everything."
            case .custom: "This file was edited outside Tinycast."
            }
        }

        /// The `ratings` object this writes. `nil` for `custom`, which is only ever read.
        fileprivate var ratings: [String: [String]]? {
            switch self {
            case .rottenTomatoes:
                ["movie": ["rt"], "tv": ["rt"], "fallback": ["imdb"]]
            case .rottenTomatoesAndMetacritic:
                ["movie": ["rt", "metacritic"], "tv": ["rt"], "fallback": ["imdb"]]
            case .imdbOnly:
                ["movie": ["imdb"], "tv": ["imdb"], "fallback": []]
            case .custom:
                nil
            }
        }

        /// True when the file says exactly this — same keys, same order, nothing extra. An extra key
        /// means someone edited it beyond these choices, which is `custom` and never a rewrite.
        fileprivate func matches(_ file: [String: Any]) -> Bool {
            guard let expected = ratings, file.count == expected.count else { return false }
            return expected.allSatisfy { key, value in
                let written = (file[key] as? [String]) ?? (file[key] as? String).map { [$0] }
                return written == value
            }
        }
    }

    /// The provider's own default when there is no file, so a fresh install reports what it will use.
    static func choice(inCache directory: URL, fileManager: FileManager = .default) -> Choice {
        guard let file = ratingsObject(inCache: directory, fileManager: fileManager) else {
            return .rottenTomatoes
        }
        return Choice.allCases.first { $0.matches(file) } ?? .custom
    }

    /// Writes the choice, preserving every key the file already carries outside `ratings`.
    static func write(
        _ choice: Choice, inCache directory: URL, fileManager: FileManager = .default
    ) {
        guard let ratings = choice.ratings else { return }
        let path = directory.appendingPathComponent("config.json")
        var root: [String: Any] = [:]
        if let data = fileManager.contents(atPath: path.path),
            let object = try? JSONSerialization.jsonObject(with: data),
            let existing = object as? [String: Any]
        {
            root = existing
        }
        root["ratings"] = ratings
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: path)
    }

    private static func ratingsObject(
        inCache directory: URL, fileManager: FileManager
    ) -> [String: Any]? {
        let path = directory.appendingPathComponent("config.json")
        guard let data = fileManager.contents(atPath: path.path),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ratings = root["ratings"] as? [String: Any], !ratings.isEmpty
        else { return nil }
        return ratings
    }
}
