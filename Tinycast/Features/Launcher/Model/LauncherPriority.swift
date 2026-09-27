import Foundation

/// `LauncherOrder.Signals.priority`: what decides two rows the query cannot tell apart, higher first.
///
/// A native kind owns one unit of the scale. Every root-search provider row shares `.extensionResult`,
/// so relevance cannot separate two of them, and they all sit in the units below the native kinds —
/// the provider's declared precedence picks the unit (higher wins) and the provider's own score fills
/// that unit's thousandths. Two providers' scores are relative to their own matcher, so only the
/// precedence may compare them; the score only ever orders one provider's rows against each other. The
/// whole band stays below the lowest native kind, so a query that cannot tell a provider row from an
/// app still prefers the app.
enum LauncherPriority {
    /// What one unit is worth, and so the resolution a provider's score is read at.
    static let unit = 1000
    /// How many precedences the units below the native kinds hold. A provider declaring more than this
    /// is clamped into the band rather than allowed to reach a native kind.
    static let maxProviderPrecedence = 9

    /// A native kind's `rankPriority`, lifted into the scale. Their order is untouched: every kind
    /// moves by the same factor.
    static func native(rank: Int) -> Int { rank * bands }

    /// A provider row's priority: its declared precedence first, its own score within that precedence.
    ///
    /// Precedence 0 — a provider that declares none — reproduces the band a provider had before
    /// precedence existed exactly: `-unit + round(score × (unit - 1))`.
    static func provider(precedence: Int, score: Double) -> Int {
        let band = min(max(precedence, 0), maxProviderPrecedence)
        let strength = Int((min(max(score, 0), 1) * Double(unit - 1)).rounded())
        return (band - 1) * unit + strength
    }

    /// How much room the native kinds keep for the whole provider band: every precedence's unit, and
    /// the top of the highest one still falls short of the lowest native kind.
    private static var bands: Int { unit * (maxProviderPrecedence + 1) }
}
