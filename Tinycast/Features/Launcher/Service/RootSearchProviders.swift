import Foundation

// The root-search candidate provider primitive (plan §1). An extension contributes a small,
// query-dependent set of results into root search without entering the persistent `AppIndex`;
// Tinycast folds the few returned into its existing ranking for that one query.
//
// The coordinator renders one settled FRAME: core (native) results blended with the providers'
// async candidates, computed ~100ms after the latest keystroke so both appear together instead of a
// core-only render that flashes when the extension's results land. `LauncherScreen` reads the frame
// (a pure read) and the palette fires `queryChanged` on each keystroke. A stale generation or a
// result past the deadline is dropped, so an extension answering a previous keystroke never wins.

/// One transient candidate a provider contributes. It becomes an `AppEntry` only for the query at
/// hand; nothing about it is persisted, learned, pinned or hidden.
struct RootSearchCandidate: Sendable {
    /// Provider-scoped item id, e.g. `tmdb:603`. Stable so selection can route back to the provider.
    let id: String
    let title: String
    /// Rendered beside the name (a movie's year, an issue's repo). Never ranked as strongly as the
    /// title — see `RootSearchProviders.frame`.
    let subtitle: String?
    /// Lower-trust searchable text (a director, an original title): matches weaker than the title.
    let keywords: [String]
    /// Optional poster image URL, streamed into the row icon asynchronously (never fetched on the
    /// render path).
    let posterURL: String?
    /// The row's kind label (e.g. "Movie"). Nil falls back to the provider id, capitalized.
    let label: String?

    init(id: String, title: String, subtitle: String? = nil, keywords: [String] = [],
        posterURL: String? = nil, label: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.posterURL = posterURL
        self.label = label
    }
}

/// A source of transient root-search candidates. Swift providers implement this directly; a JS
/// extension's `registerRootSearchProvider` is adapted into one by the provider host.
@MainActor
protocol RootSearchProvider: AnyObject {
    /// Stable per provider, e.g. `movies`.
    var id: String { get }
    /// Return up to `limit` candidates for `query`. May be slow (a JS provider's round-trip), so the
    /// coordinator awaits it off the render path and drops it past the deadline.
    func candidates(for query: String, limit: Int) async -> [RootSearchCandidate]
    /// Get ready ahead of the first query. A provider with a cold start — a JS session to boot, an
    /// index to mount — would otherwise spend its first query's settle budget booting and render
    /// nothing, so the palette warms providers as it opens and the boot overlaps with typing.
    func warm() async
    /// Let go of whatever `warm()` mounted. A provider holding a mounted corpus is the largest thing
    /// in the app that is only needed while the palette is up, so it is released when it closes.
    func release() async
    /// Run the selected candidate's default action; `resultID` is a `RootSearchCandidate.id`.
    func perform(resultID: String) async throws
}

extension RootSearchProvider {
    func warm() async {}
    func release() async {}
}

/// Owns every registered provider and shapes their candidates into the root-search frame. Owned by
/// `AppCore`, which wires `core(for:)` to rank the native index. All state is mutated only off the
/// render path (`queryChanged`/`refresh`); `frame(for:)` is a pure read, because `LauncherScreen`
/// calls it inside a SwiftUI getter and a write there would invalidate the view every render.
@MainActor
@Observable
final class RootSearchProviders {
    /// Below this many characters no provider is consulted: a million-row corpus answers nothing
    /// useful to `m`.
    let minimumQueryLength: Int
    /// How many candidates Tinycast lets a provider contribute before ranking, whatever its corpus.
    let resultCap: Int
    /// The settle ceiling, in milliseconds: a frame resolves once every provider has answered, or
    /// when this elapses — whichever comes first.
    let settleMs: Int

    /// Bumped on every query change; a result carrying an older value is stale and discarded.
    private var generation = 0
    /// The trimmed query the frame answers.
    private var lastQuery: String = ""
    /// The query currently settling; the previous frame is held for it (no flash).
    private var pendingQuery: String = ""
    /// The settled frame: core results blended with providers' candidates, replaced only on settle.
    private var lastFrame: [AppEntry] = []
    /// Bumped on settle, so the palette re-runs `LauncherScreen`.
    var candidatesRevision = 0
    /// In-flight refresh, cancelled by a new keystroke.
    private var refreshTask: Task<Void, Never>?

    private var providers: [RootSearchProvider] = []
    /// Ranks the native index for a query; wired by `AppCore`. `@ObservationIgnored` so mutation
    /// here never counts as a view dependency.
    @ObservationIgnored private var coreFor: (String) -> [AppEntry] = { _ in [] }  // placeholder

    init(
        minimumQueryLength: Int = 2, resultCap: Int = 10, settleMs: Int = 100
    ) {
        self.minimumQueryLength = minimumQueryLength
        self.resultCap = resultCap
        self.settleMs = settleMs
    }

    func register(_ provider: RootSearchProvider) {
        providers.append(provider)
    }

    /// The registered providers' ids, for a surface outside the launcher that has to ask about them —
    /// the settings pane reports each provider's index freshness from this.
    var registeredIDs: [String] { providers.map(\.id) }

    /// Boot every provider with a cold start. Called as the palette opens, unawaited, so the boot
    /// overlaps with the user typing rather than landing inside the first frame's settle budget.
    func warmAll() async {
        for provider in providers {
            await provider.warm()
        }
    }

    /// Let the providers go as the palette closes, releasing whatever `warmAll()` mounted. The next
    /// open re-warms; a provider's own caches make that a re-mount, not a re-download.
    func releaseAll() async {
        for provider in providers {
            await provider.release()
        }
        // Releasing the session frees its pages, but the allocator keeps them in the process
        // footprint until asked — so a torn-down provider would still show its high-water mark.
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
    }

    /// Wired by `AppCore`: ranks the native index for `query`, the "core" half of the frame.
    func setCore(_ coreFor: @escaping (String) -> [AppEntry]) {
        self.coreFor = coreFor
    }

    /// The settled root-search frame for `query` — core results blended with providers' async
    /// candidates. PURE READ: never mutates this `@Observable` object (a write would loop the SwiftUI
    /// getter). The previous frame is held while a refresh for `query` is still settling.
    func frame(for query: String) -> [AppEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Hold the last settled frame for the query being refreshed (or the settled query), so the
        // core + async rows appear together once instead of a core-only flash.
        guard trimmed == lastQuery || trimmed == pendingQuery else { return [] }
        return lastFrame
    }

    /// Called on every root-query change (from the palette's `onChange(of: vm.query)` handler, off
    /// the render path). Bumps the generation and fires a settling refresh; the previous frame is
    /// held until it settles.
    func queryChanged(for query: String) {
        generation &+= 1
        refreshTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        pendingQuery = trimmed
        if trimmed.count >= minimumQueryLength {
            let generator = generation
            refreshTask = Task { @MainActor in
                await refresh(for: trimmed, generation: generator)
            }
        } else {
            // Too short to ask any provider: settle immediately (no async rows expected).
            lastQuery = trimmed
            pendingQuery = ""
            lastFrame = coreFor(trimmed)
            candidatesRevision &+= 1
        }
    }

    /// Blend the native core with the providers' candidates and publish the frame. Resolves as soon
    /// as every provider has answered, but never later than `settleMs`: `collectCandidates` returns
    /// partials past its `until`, so a slow provider can't stretch the layout out. A stale
    /// generation is dropped wholesale.
    private func refresh(for trimmed: String, generation: Int) async {
        guard generation == self.generation else { return }
        let expiresAt = ContinuousClock.now.advanced(by: .milliseconds(settleMs))
        let async = await Self.collectCandidates(
            providers, for: trimmed, limit: resultCap, until: expiresAt)
        guard generation == self.generation else { return }
        let core = coreFor(trimmed)
        lastQuery = trimmed
        pendingQuery = ""
        lastFrame = Self.merge(core, async)
        candidatesRevision &+= 1
    }

    /// Blend the native core with the providers' candidates, letting the async rows rank where they
    /// naturally fit without pushing the core's own ordering out: core first in its ranked order, then
    /// the async rows (which SearchRelevance already trust-bounded). Async never outranks equal core.
    private static func merge(_ core: [AppEntry], _ async: [AppEntry]) -> [AppEntry] {
        core + async
    }

    /// Run every provider once, building transient entries; stops early past `until` (the deadline).
    private static func collectCandidates(
        _ providers: [RootSearchProvider], for trimmed: String, limit: Int, until: ContinuousClock.Instant?
    ) async -> [AppEntry] {
        var all: [AppEntry] = []
        for provider in providers {
            if let until, ContinuousClock.now >= until { break }
            do {
                try all += RootSearchProviders.entry(
                    providerID: provider.id, candidates: await provider.candidates(for: trimmed, limit: limit))
            } catch {}
        }
        return all
    }

    /// Route activation back to the owning provider. Activation failures never reach the palette:
    /// they are the provider's own to report, so `perform` does not throw.
    func perform(entry: AppEntry) async {
        guard let (providerID, resultID) = RootSearchProviders.split(entry.id) else { return }
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        do {
            try await provider.perform(resultID: resultID)
        } catch { return }
    }

    /// The transient `AppEntry`s a provider's candidates become. Title is `.name` (strongest);
    /// keywords ride as `.translation` (weaker, so a director hit loses to a title hit); the
    /// provider id is `.owner`, the weakest literal band, the same trust asked of an extension title.
    static func entry(providerID: String, candidates: [RootSearchCandidate]) -> [AppEntry] {
        candidates.map { candidate -> AppEntry in
            let id = "root-search:\(providerID):\(candidate.id)"
            var entry = AppEntry(
                id: id, name: candidate.title,
                url: URL(string: "tinycast://root-result/\(id)")!,
                bundleID: nil, kind: .extensionResult,
                subtitle: candidate.subtitle,
                // Display label: the provider's own singular label ("Movie"), else the id capitalized.
                ownerName: candidate.label ?? providerID.localizedCapitalized)
            // A candidate carrying a poster URL streams it into the row icon asynchronously; the
            // placeholder renders until the fetch+cache lands.
            if let posterURL = candidate.posterURL,
                let url = URL(string: posterURL)
            {
                entry.iconOverride = .poster(url: url)
            }
            entry.aliases =
                [SearchAlias.name(candidate.title)]
                + candidate.keywords.compactMap { SearchAlias.translation($0) }
                + [SearchAlias.owner(providerID)]
            return entry
        }
    }

    private static func split(_ entryID: String) -> (String, String)? {
        let prefix = "root-search:".count
        guard entryID.count > prefix else { return nil }
        let components = entryID.dropFirst(prefix).split(separator: ":")
        guard components.count >= 2 else { return nil }
        return (String(components[0]), components.dropFirst(1).joined(separator: ":"))
    }
}