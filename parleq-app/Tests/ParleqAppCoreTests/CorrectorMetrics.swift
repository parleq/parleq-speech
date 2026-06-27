/// Pure value-type corrector metrics: counts recovery and over-fire outcomes
/// across intent buckets, and compares tallies against a baseline.
///
/// Used by the audio regression harness (Task 2+). No I/O or model dependencies.
enum CorrectorMetrics {

    /// One clip's outcome after running the corrector.
    ///
    /// - `intent`:    the bucket label for the clip (e.g. "keavi", "fruit", "control").
    /// - `recovered`: true iff the corrector output contained the target term
    ///                (only meaningful for term-intent clips).
    /// - `overFired`: true iff the corrector output wrongly contains ANY term
    ///                (only meaningful for non-term / control clips).
    struct Outcome {
        let intent: String
        let recovered: Bool
        let overFired: Bool
    }

    /// Per-intent aggregate counts.
    struct Tally: Codable, Equatable {
        let recovered: Int
        let total: Int
        let overFired: Int
    }

    /// Aggregate a flat list of outcomes into a per-intent tally dictionary.
    ///
    /// - `recovered` counts clips where `outcome.recovered == true`.
    /// - `total` counts all clips for that intent.
    /// - `overFired` counts clips where `outcome.overFired == true`.
    static func tally(_ outcomes: [Outcome]) -> [String: Tally] {
        var buckets: [String: (recovered: Int, total: Int, overFired: Int)] = [:]
        for o in outcomes {
            var b = buckets[o.intent] ?? (0, 0, 0)
            b.total += 1
            if o.recovered { b.recovered += 1 }
            if o.overFired  { b.overFired  += 1 }
            buckets[o.intent] = b
        }
        return buckets.mapValues { Tally(recovered: $0.recovered, total: $0.total, overFired: $0.overFired) }
    }

    /// Compare `got` against `baseline`.
    ///
    /// An intent regresses if:
    ///   - `got.recovered < baseline.recovered - tolerance`, OR
    ///   - `got.overFired > baseline.overFired + tolerance`.
    ///
    /// Returns `(ok: true, regressions: [])` when no regressions are found.
    /// Intents present in `baseline` but absent from `got` are treated as regressions
    /// (recovered=0, overFired=0 against the baseline).
    static func withinBaseline(
        _ got: [String: Tally],
        baseline: [String: Tally],
        tolerance: Int
    ) -> (ok: Bool, regressions: [String]) {
        var regressions: [String] = []
        for (intent, base) in baseline {
            let g = got[intent] ?? Tally(recovered: 0, total: 0, overFired: 0)
            let recoveryRegressed = g.recovered < base.recovered - tolerance
            let overFireRegressed = g.overFired  > base.overFired  + tolerance
            if recoveryRegressed || overFireRegressed {
                regressions.append(intent)
            }
        }
        return (ok: regressions.isEmpty, regressions: regressions)
    }
}
