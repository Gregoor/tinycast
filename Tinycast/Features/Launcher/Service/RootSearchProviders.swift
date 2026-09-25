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

/// One action a provider offers for a candidate, in the vocabulary an extension's own `ActionPanel`
/// uses: a title, an optional glyph and chord, and where a new section begins.
///
/// Raycast's `Action` carries the closure it runs; across the JS boundary an id has to instead, and the
/// provider already knows what its own ids mean — it receives one alongside the result.
struct RootSearchAction: Sendable, Equatable {
    let id: String
    let title: String
    /// An SF Symbol name, or a URL for artwork. Nil leaves the row's default glyph.
    let icon: String?
    /// Shown beside the title. The app binds nothing to it; the provider decides what to advertise.
    let shortcut: String?
    let startsSection: Bool

    init(
        id: String, title: String, icon: String? = nil, shortcut: String? = nil,
        startsSection: Bool = false
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.startsSection = startsSection
    }
}

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
    /// An image shipped beside the provider's own bundle, as a path relative to it — resolved by the
    /// host, which refuses anything outside that directory. Drawn synchronously, so it beats a poster.
    let iconPath: String?
    /// The row's kind label (e.g. "Movie"). Nil falls back to the provider id, capitalized.
    let label: String?
    /// What ⌘K offers for this row. The first is the default, so ↵ runs it and no separate concept is
    /// needed — the same convention `ActionPanel` follows. Empty falls back to the app's own "Open".
    let actions: [RootSearchAction]
    /// Provider-relative strength on 0…1 — an article's traffic, a film's vote count — which orders a
    /// provider's own rows against each other. Never compared across providers: the scales don't
    /// correspond. Nil ranks as the weakest.
    let score: Double?

    init(
        id: String, title: String, subtitle: String? = nil, keywords: [String] = [],
        posterURL: String? = nil, iconPath: String? = nil, label: String? = nil,
        actions: [RootSearchAction] = [], score: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.posterURL = posterURL
        self.iconPath = iconPath
        self.label = label
        self.actions = actions
        self.score = score
    }
}

/// A source of transient root-search candidates. Swift providers implement this directly; a JS
/// extension's `registerRootSearchProvider` is adapted into one by the provider host.
@MainActor
protocol RootSearchProvider: AnyObject {
    /// Stable per provider, e.g. `movies`.
    var id: String { get }
    /// Return up to `limit` candidates for `query`. May be slow (a JS provider's round-trip), so the
    /// coordinator awaits it off the render path and drops it past the deadline. A provider with a cold
    /// start boots itself here without waiting: a boot mounts an index and may sync one, and no
    /// keystroke can wait for that, so the query that finds it cold answers nothing and the next one
    /// answers instead.
    func candidates(for query: String, limit: Int) async -> [RootSearchCandidate]
    /// Let go of whatever a query mounted. A provider holding a mounted corpus is the largest thing in
    /// the app that is only needed while the palette is up, so it is released when it closes.
    func release() async
    /// Start whatever a query would otherwise have to wait for, as the launcher opens. A provider whose
    /// first query is already cheap does nothing here.
    func warm()
    /// Run one of the selected candidate's actions; `resultID` is a `RootSearchCandidate.id` and
    /// `actionID` is one of the ids it listed, or nil for the default — which is its first action.
    func perform(resultID: String, actionID: String?) async throws
}

extension RootSearchProvider {
    func release() async {}
    func warm() {}
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

    /// How long each provider takes to answer, recorded per completed query and read by Settings.
    let timings = ProviderTimingStore()

    /// Bumped on every query change; a result carrying an older value is stale and discarded.
    private var generation = 0
    /// The trimmed query the frame answers.
    private var lastQuery: String = ""
    /// The query currently settling; the previous frame is held for it (no flash).
    private var pendingQuery: String = ""
    /// The settled frame: core results blended with providers' candidates, replaced only on settle.
    private var lastResults = AppIndex.Results()
    /// Bumped on settle, so the palette re-runs `LauncherScreen`.
    var candidatesRevision = 0
    /// In-flight refresh, cancelled by a new keystroke.
    private var refreshTask: Task<Void, Never>?

    private var providers: [RootSearchProvider] = []
    /// The actions each transient row listed, by entry id. Replaced on every settle alongside the
    /// rows themselves, so a stale menu can never outlive the query that produced it.
    private var actionsByEntry: [String: [RootSearchAction]] = [:]
    /// What each provider has answered for the query being settled, by registration index, and how many
    /// have answered. `@ObservationIgnored`: bookkeeping rather than view state — the revision is the
    /// signal, and publishing is what the view reads.
    @ObservationIgnored private var collected: [[(entry: AppEntry, actions: [RootSearchAction])]] = []
    @ObservationIgnored private var answered = 0
    /// The providers that answered after the frame had already gone out. Their rows are appended rather
    /// than ranked, so a provider that took a second cannot push a row in above results being read.
    @ObservationIgnored private var late: Set<Int> = []
    /// The generation whose frame has gone out, so an answer that lands afterwards republishes it.
    @ObservationIgnored private var publishedGeneration = -1
    /// When the providers were asked, so an answer's cost can be measured where it lands.
    @ObservationIgnored private var askedAt: ContinuousClock.Instant?
    /// Ranks the native index for a query — plus a provider's rows, when there are any, so the two
    /// halves are ordered together. Wired by `AppCore`. `@ObservationIgnored` so mutation here never
    /// counts as a view dependency.
    @ObservationIgnored private var coreFor: (String, [AppEntry]) -> AppIndex.Results = { _, _ in
        AppIndex.Results()
    }

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

    /// The activation a row started, held so `releaseAll` can let it finish. Releasing mid-call tears
    /// down the provider's context and its host call never settles, so the row silently does nothing.
    private var activation: Task<Void, Never>?

    /// Run a row's action and own the Task until it lands, so closing the palette cannot cut it short.
    func activate(entry: AppEntry, actionID: String? = nil) {
        activation = Task { await perform(entry: entry, actionID: actionID) }
    }

    /// Boot every provider as the launcher opens. A mount is tens of milliseconds on the provider's own
    /// runtime and a cold one is far more, so the query path should never be the first to ask for it.
    func warmAll() {
        for provider in providers { provider.warm() }
    }

    /// How long a closed palette keeps its mounted providers. Reopening within the window is common —
    /// glance, close, reopen — and a mount is the one cost worth not repeating for that.
    nonisolated static let releaseGrace: Duration = .seconds(10)

    /// The pending release, cancelled by the next open.
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    /// The palette opened: boot every provider, and keep whatever a grace window was still holding.
    func paletteOpened() {
        releaseTask?.cancel()
        releaseTask = nil
        warmAll()
    }

    /// The palette closed: hold the mounted providers for the grace window, then let them go. Closing
    /// again restarts the window, so it is always ten seconds after the last close.
    func paletteClosed() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseGrace)
            guard !Task.isCancelled else { return }
            await self?.releaseAll()
        }
    }

    /// Let the providers go as the palette closes, releasing whatever a query mounted. The next query
    /// that needs one mounts it again; a provider's own caches make that a re-mount, not a re-download.
    /// Private because the palette closes through `paletteClosed`, which is what makes the window exist.
    private func releaseAll() async {
        // Awaited first: the palette is already hidden, so a provider that never answers only delays the
        // release, never the close.
        await activation?.value
        activation = nil
        for provider in providers {
            await provider.release()
        }
        // Releasing the session frees its pages, but the allocator keeps them in the process
        // footprint until asked — so a torn-down provider would still show its high-water mark.
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
    }

    /// Wired by `AppCore`: the native index's ranking for `query`, with any provider's transient rows
    /// folded into it — `frame`'s two halves, ranked as one.
    func setCore(_ coreFor: @escaping (String, [AppEntry]) -> AppIndex.Results) {
        self.coreFor = coreFor
    }

    /// The settled root-search frame for `query` — the core's results with the providers' async
    /// candidates folded into them. PURE READ: never mutates this `@Observable` object (a write would
    /// loop the SwiftUI getter). The previous frame is held while a refresh for `query` is settling.
    func results(for query: String) -> AppIndex.Results {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Hold the last settled frame for the query being refreshed (or the settled query), so the
        // core + async rows appear together once instead of a core-only flash.
        guard trimmed == lastQuery || trimmed == pendingQuery else { return AppIndex.Results() }
        return lastResults
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
            lastResults = coreFor(trimmed, [])
            actionsByEntry = [:]
            candidatesRevision &+= 1
        }
    }

    /// Ask every provider for `trimmed`, then publish. The frame goes out once they have all answered
    /// or at `settleMs`, whichever comes first, carrying whatever arrived in time; a provider slower
    /// than that is appended to the end instead — see `collect`. A stale generation is dropped whole.
    private func refresh(for trimmed: String, generation: Int) async {
        guard generation == self.generation else { return }
        // Asked together rather than in turn: in sequence, a provider that spent the whole window was
        // the last one asked, so whether a provider answered at all depended on registration order.
        collected = Array(repeating: [], count: providers.count)
        late = []
        answered = 0
        askedAt = ContinuousClock.now
        for (index, provider) in providers.enumerated() {
            Task { @MainActor in
                let candidates = await provider.candidates(for: trimmed, limit: self.resultCap)
                self.collect(
                    candidates, providerID: provider.id, at: index, query: trimmed,
                    generation: generation)
            }
        }
        let expiresAt = ContinuousClock.now.advanced(by: .milliseconds(settleMs))
        // Settle on whichever comes first: every provider's answer, or the ceiling.
        while answered < providers.count, ContinuousClock.now < expiresAt {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard generation == self.generation else { return }
        publish(trimmed, generation: generation)
    }

    /// One provider's answer, into the frame being settled. A reply that lands after the frame went out
    /// is appended rather than ranked, so a provider that took a second cannot push a row in above
    /// results the user is already reading.
    private func collect(
        _ candidates: [RootSearchCandidate], providerID: String, at index: Int, query: String,
        generation: Int
    ) {
        guard generation == self.generation, collected.indices.contains(index) else { return }
        // Timed where the answer lands: a superseded one never reaches here, which is what keeps an
        // interrupted query out of the numbers.
        if let askedAt {
            let elapsed = askedAt.duration(to: .now)
            timings.record(
                providerID: providerID,
                milliseconds: Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15)
        }
        collected[index] = Self.entry(providerID: providerID, candidates: candidates)
        answered += 1
        guard publishedGeneration == generation else { return }
        // Already settled: this provider missed the frame, so its rows go to the end of the list.
        late.insert(index)
        publish(query, generation: generation)
    }

    /// Fold what arrived in time into the core's ranking, append what arrived after it, and show the
    /// frame. The counts describe the core's own leading rows and are only ever non-zero for an empty
    /// query, which is below every provider's minimum length — so folding cannot put them out of step
    /// with `entries`.
    private func publish(_ query: String, generation: Int) {
        var inTime: [(entry: AppEntry, actions: [RootSearchAction])] = []
        var stragglers: [(entry: AppEntry, actions: [RootSearchAction])] = []
        for (index, rows) in collected.enumerated() {
            if late.contains(index) { stragglers += rows } else { inTime += rows }
        }
        let ranked = coreFor(query, inTime.map(\.entry))
        lastResults = AppIndex.Results(
            entries: ranked.entries + stragglers.map(\.entry),
            favoriteCount: ranked.favoriteCount, suggestionCount: ranked.suggestionCount)
        let rows = inTime + stragglers
        actionsByEntry = Dictionary(uniqueKeysWithValues: rows.map { ($0.entry.id, $0.actions) })
        lastQuery = query
        pendingQuery = ""
        publishedGeneration = generation
        candidatesRevision &+= 1
    }

    /// Route activation back to the owning provider. Activation failures never reach the palette:
    /// they are the provider's own to report, so this does not throw. Private because every caller has
    /// to hand its Task to `activation` — a bare Task here is what `releaseAll` used to race.
    private func perform(entry: AppEntry, actionID: String?) async {
        guard let (providerID, resultID) = RootSearchProviders.split(entry.id) else { return }
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        do {
            try await provider.perform(resultID: resultID, actionID: actionID)
        } catch { return }
    }

    /// ⌘K's items for a provider row, or nil for every other kind so the launcher keeps its own menu.
    /// The provider names the actions; the app supplies the closures, so a bundle still reaches nothing
    /// but its own `perform`. A provider listing none gets the launcher's single "Open" instead.
    func actionItems(for entry: AppEntry) -> [PopoverMenuItem]? {
        guard entry.kind == .extensionResult, RootSearchProviders.split(entry.id) != nil else { return nil }
        let actions = actionsByEntry[entry.id] ?? []
        guard !actions.isEmpty else { return nil }
        return actions.enumerated().map { index, action in
            PopoverMenuItem(
                title: action.title,
                icon: action.icon.map(PopoverMenuIcon.symbol) ?? .symbol("arrow.up.forward.app"),
                startsSection: index == 0 ? false : action.startsSection,
                shortcut: index == 0 ? "↵" : action.shortcut
            ) { [weak self] in
                self?.activate(entry: entry, actionID: action.id)
            }
        }
    }

    /// The transient `AppEntry`s a provider's candidates become. Title is `.name` (strongest);
    /// keywords ride as `.translation` (weaker, so a director hit loses to a title hit); the
    /// provider id is `.owner`, the weakest literal band, the same trust asked of an extension title.
    /// Each candidate with the actions it listed, so the row's menu can be built without asking the
    /// provider again.
    static func entry(
        providerID: String, candidates: [RootSearchCandidate]
    ) -> [(entry: AppEntry, actions: [RootSearchAction])] {
        candidates.map { candidate -> (entry: AppEntry, actions: [RootSearchAction]) in
            let id = "root-search:\(providerID):\(candidate.id)"
            var entry = AppEntry(
                id: id, name: candidate.title,
                url: URL(string: "tinycast://root-result/\(id)")!,
                bundleID: nil, kind: .extensionResult,
                subtitle: candidate.subtitle,
                // Display label: the provider's own singular label ("Movie"), else the id capitalized.
                ownerName: candidate.label ?? providerID.localizedCapitalized,
                providerScore: candidate.score)
            // A provider may ship the row's own icon beside its bundle; it wins over a streamed poster,
            // because it is the deliberate one. Both are async or cached — never a fetch on this path.
            if let path = candidate.iconPath {
                entry.iconOverride = .artwork(path: path, extent: ExtensionIconCache.extent)
            } else if let posterURL = candidate.posterURL, let url = URL(string: posterURL) {
                entry.iconOverride = .poster(url: url)
            }
            // A provider's keywords are the title's other spellings — an original title, a translation —
            // which rank like the name. Never `keywords`: those are only ever found by, not ranked.
            for alternate in candidate.keywords {
                entry.addAlternateTitle(alternate)
            }
            // Ranked like every other row, so the profile has to exist: until this was built the rows
            // only ever appeared by being appended.
            entry.buildSearchProfile()
            return (entry, candidate.actions)
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
