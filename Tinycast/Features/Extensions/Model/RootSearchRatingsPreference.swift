import Foundation

/// Which ratings a root-search provider shows on its result rows, and in what order — the preference
/// the app writes and the provider reads back from its own cache.
///
/// The provider knows three sources and renders the media type's list in order, falling back to its
/// own list only when that one has nothing for the title. So the order is the settings, not a detail
/// of them: a row prints the first source that has a score.
///
/// The layout in `order` is the app's, not the file's — it exists so a source that is switched off
/// keeps its place among the rows instead of jumping to the end. What gets written is only `listed`.
struct RootSearchRatingsPreference: Sendable, Equatable {
    enum Source: String, CaseIterable, Sendable {
        case rt
        case metacritic
        case imdb

        var title: String {
            switch self {
            case .rt: "Rotten Tomatoes"
            case .metacritic: "Metacritic"
            case .imdb: "IMDb"
            }
        }

        /// What a row will actually show, so the choice reads as the thing it produces.
        var detail: String {
            switch self {
            case .rt: "The tomato, or the splat under 60%."
            case .metacritic: "A green, yellow or red dot."
            case .imdb: "The star."
            }
        }
    }

    /// One media type's rows and what is listed for it. The defaults are the provider's own.
    struct Media: Sendable, Equatable {
        var order: [Source] = Source.allCases
        var shown: Set<Source> = [.rt]

        /// The config's list: the shown sources, in the order the rows are laid out.
        var listed: [Source] { order.filter(shown.contains) }
    }

    var movie = Media()
    var tv = Media()
    /// Neither edited here nor derived: whatever the file already said, so a hand-written fallback
    /// survives a change made in Settings.
    var fallback: [Source] = [.imdb]

    static func read(inCache directory: URL, fileManager: FileManager = .default) -> Self {
        guard let ratings = ratingsObject(inCache: directory, fileManager: fileManager) else {
            return Self()
        }
        var preference = Self()
        preference.movie = media(ratings["movie"])
        preference.tv = media(ratings["tv"])
        if let fallback = ratings["fallback"] as? [String] {
            preference.fallback = fallback.compactMap(Source.init(rawValue:))
        }
        return preference
    }

    /// Writes the preference, keeping every key the file already carries outside `ratings`.
    func write(inCache directory: URL, fileManager: FileManager = .default) {
        let path = directory.appendingPathComponent("config.json")
        var root: [String: Any] = [:]
        if let data = fileManager.contents(atPath: path.path),
            let object = try? JSONSerialization.jsonObject(with: data),
            let existing = object as? [String: Any]
        {
            root = existing
        }
        root["ratings"] = [
            "movie": movie.listed.map(\.rawValue),
            "tv": tv.listed.map(\.rawValue),
            "fallback": fallback.map(\.rawValue),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: path)
    }

    /// A list the provider could also write as a bare string, ordered as the config listed it with the
    /// unlisted sources after.
    private static func media(_ value: Any?) -> Media {
        let listed = ((value as? [String]) ?? (value as? String).map { [$0] } ?? [])
            .compactMap(Source.init(rawValue:))
        var media = Media()
        media.shown = Set(listed)
        media.order = listed + Source.allCases.filter { !media.shown.contains($0) }
        return media
    }

    private static func ratingsObject(
        inCache directory: URL, fileManager: FileManager
    ) -> [String: Any]? {
        let path = directory.appendingPathComponent("config.json")
        guard let data = fileManager.contents(atPath: path.path),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let ratings = root["ratings"] as? [String: Any], !ratings.isEmpty
        else { return nil }
        return ratings
    }
}
