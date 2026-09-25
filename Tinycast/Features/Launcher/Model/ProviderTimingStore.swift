import Foundation

/// How long each root-search provider takes to answer, so Settings can say it rather than guess.
///
/// Only a query that ran to completion is recorded: an answer that arrives after the user has typed
/// again belongs to a frame nobody saw. Samples are bounded and the percentiles come from the samples,
/// because a mean alone would hide exactly the stragglers this exists to expose.
@MainActor
@Observable
final class ProviderTimingStore {
    struct Stats: Equatable, Sendable {
        /// Every answer ever recorded, not just those still sampled.
        let count: Int
        let average: Double
        let p95: Double
        let p99: Double
    }

    /// How many of the most recent answers are kept per provider: enough for a p99 to mean something,
    /// without the file growing with use.
    nonisolated static let sampleLimit = 200
    /// A keystroke asks every provider, so writes are coalesced rather than made per answer.
    nonisolated static let persistInterval: TimeInterval = 30

    private struct Record: Codable {
        var count: Int
        var samples: [Double]
    }

    private let fileURL: URL
    private let now: () -> Date
    private var records: [String: Record] = [:]
    private var lastPersist = Date.distantPast
    /// The in-flight persist, awaited by the next one so a burst cannot land out of order.
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.now = now
        records =
            (try? Data(contentsOf: self.fileURL))
            .flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }

    /// Awaits the pending persist, writing first. The launcher never needs it; reading the file does.
    func flush() async {
        persist()
        await writeTask?.value
    }

    /// One completed answer, in milliseconds.
    func record(providerID: String, milliseconds: Double) {
        guard !providerID.isEmpty, milliseconds.isFinite, milliseconds >= 0 else { return }
        var record = records[providerID] ?? Record(count: 0, samples: [])
        record.count += 1
        record.samples.append(milliseconds)
        if record.samples.count > Self.sampleLimit {
            record.samples.removeFirst(record.samples.count - Self.sampleLimit)
        }
        records[providerID] = record
        guard now().timeIntervalSince(lastPersist) >= Self.persistInterval else { return }
        persist()
    }

    func stats(for providerID: String) -> Stats? {
        guard let record = records[providerID], !record.samples.isEmpty else { return nil }
        let sorted = record.samples.sorted()
        return Stats(
            count: record.count,
            average: record.samples.reduce(0, +) / Double(record.samples.count),
            p95: Self.percentile(sorted, 0.95),
            p99: Self.percentile(sorted, 0.99))
    }

    /// Nearest rank: no interpolation is honest at this sample size, and it can only return a value
    /// that was actually observed.
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private func persist() {
        lastPersist = now()
        let payload = records
        let url = fileURL
        let previous = writeTask
        writeTask = Task {
            await previous?.value
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Application Support, not Caches: how fast a provider is takes weeks of use to say anything.
    private static func defaultFileURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("launcher-provider-timings.json")
    }
}
