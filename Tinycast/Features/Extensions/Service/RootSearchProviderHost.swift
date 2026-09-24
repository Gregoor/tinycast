import AppKit
import Foundation

// A resident, headless extension session that contributes root-search candidates (plan §3–4).
//
// The extension runtime tears a command down when it finishes, so a provider cannot rely on
// `ExtensionManager.run`. This host keeps ONE `JSContext` alive while in use: it boots the runtime,
// loads a compiled extension bundle whose entry calls `registerRootSearchProvider({ id, search,
// perform })` from `@tinycast/api`, and keeps the session mounted. Swift then fires
// `__tinycast.rootSearchQuery` into it and the reply — an async `rootSearch.results` host call from
// the JS side — lands back on the main actor.
//
// The wait is a "fire then register a waiter" mailbox (the Swift-concurrency rendezvous pattern):
// `candidates` dispatches the query first (the runtime's `onQueue` returns once the JS has accepted
// it), then registers a continuation; the bridge's `results` handler publishes a stored-or-resume
// reply, so a result that beats the waiter isn't lost and every continuation resumes exactly once.
// There is no async work inside the continuation closure and no fire-and-forget Task launched from
// it, which is what keeps this Swift 6 compilation well-behaved.
//
// The host answers only `rootSearch.*` — a provider bundle can never reach storage, clipboard or the
// rest of the extension surface. All state is `@MainActor`-confined, so the mailbox needs no lock.

@MainActor
final class RootSearchProviderHost {
    private var runtime: ExtensionRuntime?
    private let bridge: RootSearchHostBridge
    private let providerID: String
    private let bundleURL: URL
    /// Where a provider keeps its own data (its index cache). Keyed by provider id, under the
    /// channel's Application Support, so a Dev build never shares a stable's cache.
    private let supportDirectory: URL
    private var started = false
    private var nextRequestID = 1

    /// One request's wait or its already-published reply. A slot holds exactly one of the two:
    /// a waiter is resumed by a later publish; a published reply is handed to a later waiter.
    private struct RequestSlot {
        enum State {
            case waiting(CheckedContinuation<Reply, Never>)
            case answered(Reply)
        }
        var state: State = .answered(Reply(candidates: [], error: nil))  // placeholder; see wait()
        init(state: State) { self.state = state }
    }

    struct Reply {
        let candidates: [RootSearchCandidate]
        let error: String?
    }

    private var slots: [String: RequestSlot] = [:]

    init(providerID: String, bundleURL: URL) {
        self.providerID = providerID
        self.bundleURL = bundleURL
        supportDirectory = ExtensionCatalog.supportPath(for: providerID)
        try? FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true)
        bridge = RootSearchHostBridge()
        bridge.host = self
    }

    var isStarted: Bool { started }
    var providerIDValue: String { providerID }

    /// Boot the runtime and load the provider bundle. Called after `init` completes so `self` never
    /// escapes half-built.
    func start() async throws {
        guard !started else { return }
        let built = ExtensionRuntime(hostAPI: bridge)
        do {
            try await built.boot(
                config: ExtensionBootConfig.current(supportDirectory: supportDirectory))
        } catch {
            throw error
        }
        let code = try String(contentsOf: bundleURL, encoding: .utf8)
        let launch = ExtensionLaunchContext(
            extensionName: "root-search", extensionTitle: providerID, commandName: "provider",
            commandMode: .noView, assetsPath: bundleURL.deletingLastPathComponent().path,
            supportPath: supportDirectory.path,
            preferences: [:], caches: [:], arguments: [:], fallbackText: nil,
            isDarkAppearance: NSApp.effectiveAppearance.isDark)
        try await built.start(
            session: "resident-provider", code: code, file: bundleURL,
            mode: .noView, context: launch)
        runtime = built
        started = true
    }

    /// Ask the JS provider for candidates. Dispatches the query, then waits on the mailbox slot for
    /// the reply (which may already have arrived).
    func candidates(for query: String, limit: Int) async -> Reply {
        guard started, let runtime else { return Reply(candidates: [], error: "provider not started") }
        let requestID = Self.nextRequestID(&nextRequestID)
        do {
            try await runtime.fireRootSearchQuery(
                session: "resident-provider", providerID: providerID,
                query: query, limit: limit, requestID: requestID)
        } catch {
            return Reply(candidates: [], error: "dispatch failed: \(error.localizedDescription)")
        }
        return await withCheckedContinuation { continuation in
            // If the reply already landed (instant JS), hand it over; else register the waiter.
            if let slot = slots[requestID] {
                if case .answered(let reply) = slot.state {
                    slots.removeValue(forKey: requestID)
                    continuation.resume(returning: reply)
                    return
                }
            }
            var slot = slots[requestID] ?? RequestSlot(state: .waiting(continuation))
            slot.state = .waiting(continuation)
            slots[requestID] = slot
        }
    }

    /// Route activation to the JS provider's `perform`.
    func perform(resultID: String) async {
        guard started, let runtime else { return }
        do {
            try await runtime.fireRootSearchPerform(providerID: providerID, resultID: resultID)
        } catch {}
    }

    /// The host bridge calls this when the JS side reports results for a request: resume the waiter,
    /// or keep the reply for a waiter still on its way.
    func resolve(requestID: String, candidates: [RootSearchCandidate], error: String?) {
        let reply = Reply(candidates: candidates, error: error)
        if let slot = slots[requestID] {
            if case .waiting(let continuation) = slot.state {
                slots.removeValue(forKey: requestID)
                continuation.resume(returning: reply)
                return
            }
        }
        var slot = requestSlot(requestID)
        slot.state = .answered(reply)
        slots[requestID] = slot
    }

    /// Tear down the resident context.
    func stop() {
        runtime?.shutdown()
        runtime = nil
        started = false
        // Abandon any in-flight waits (resuming them with an empty reply so nothing hangs).
        for (requestID, slot) in slots {
            if case .waiting(let continuation) = slot.state {
                continuation.resume(returning: Reply(candidates: [], error: nil))
            }
            slots.removeValue(forKey: requestID)
        }
    }

    private func requestSlot(_ requestID: String) -> RequestSlot {
        slots[requestID] ?? RequestSlot(state: .answered(Reply(candidates: [], error: nil)))
    }

    private static func nextRequestID(_ counter: inout Int) -> String {
        let value = counter
        counter &+= 1
        return "req-\(value)"
    }
}

/// The JS→Swift seam for a `RootSearchProviderHost`: only `rootSearch.*` is answered, so a provider
/// bundle cannot reach the rest of the extension surface.
@MainActor
final class RootSearchHostBridge: ExtensionHostAPI {
    weak var host: RootSearchProviderHost?

    func perform(api: String, method: String, arguments: [RenderValue]) async throws -> String {
        switch api {
        case "rootSearch":
            return try rootSearch(method: method, arguments: arguments)
        case "system" where method == "open":
            // A provider's only allowed action: opening a URL (popfeed). Activating a result must not
            // reach clipboard, storage, fetch or the rest of the extension surface.
            guard let target = arguments.first?.stringValue, let url = URL(string: target) else {
                return #"{"ok":false,"error":"system.open needs a URL"}"#
            }
            AppLauncher.open(url)
            return #"{"ok":true}"#
        default:
            return #"{"ok":false,"error":"root-search providers may only open a URL"}"#
        }
    }

    private func rootSearch(method: String, arguments: [RenderValue]) throws -> String {
        switch method {
        case "register", "unregister":
            return #"{"ok":true}"#
        case "results":
            guard let requestID = arguments.first?.stringValue, let host else {
                return #"{"ok":false,"error":"missing requestId or host"}"#
            }
            host.resolve(
                requestID: requestID,
                candidates: Self.decode((arguments[safe: 1]?.arrayValue ?? [])),
                error: arguments[safe: 2]?.stringValue)
            return #"{"ok":true}"#
        default:
            return #"{"ok":false,"error":"unknown rootSearch.\(method)"}"#
        }
    }

    func sessionEnded() {}

    /// Decode the `[{id,title,subtitle?,keywords?,posterURL?}]` JS array into Sendable candidates.
    private static func decode(_ items: [RenderValue]) -> [RootSearchCandidate] {
        items.compactMap { item -> RootSearchCandidate? in
            let fields = item.objectValue ?? [:]
            guard let id = fields["id"]?.stringValue, let title = fields["title"]?.stringValue else {
                return nil
            }
            let poster = fields["posterURL"]?.stringValue
            return RootSearchCandidate(
                id: id, title: title,
                subtitle: fields["subtitle"]?.stringValue,
                keywords: fields["keywords"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                posterURL: poster,
                label: fields["label"]?.stringValue)
        }
    }
}

/// Adapts a resident `RootSearchProviderHost` to the launcher's `RootSearchProvider` protocol, so
/// the coordinator's async refresh can ask a JS extension for candidates just like any provider.
/// Lives beside the host (in the Extensions feature) because that is where the runtime seam is.
@MainActor
final class JSRootSearchProvider: RootSearchProvider {
    private let host: RootSearchProviderHost

    init(host: RootSearchProviderHost) {
        self.host = host
    }

    var id: String { host.providerIDValue }

    func candidates(for query: String, limit: Int) async -> [RootSearchCandidate] {
        do {
            try await host.start()
        } catch {
            return []
        }
        let reply = await host.candidates(for: query, limit: limit)
        guard reply.error == nil else { return [] }
        return reply.candidates
    }

    func perform(resultID: String) async throws {
        await host.perform(resultID: resultID)
    }

    /// Boot the session and let the provider mount its index, then throw the empty answer away. The
    /// provider's own sync/open happens on any call, so an empty query is enough to warm it.
    func warm() async {
        _ = await candidates(for: "", limit: 0)
    }

    /// Drop the session and the mounted index. `warm()` mounts them again from the provider's cache.
    func release() async {
        host.stop()
    }
}
