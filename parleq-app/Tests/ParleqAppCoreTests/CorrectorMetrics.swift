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
    /// An intent regresses if any of:
    ///   - `got[intent]` is absent (the bucket vanished entirely), OR
    ///   - `got.recovered < baseline.recovered - recoveryTolerance`, OR
    ///   - `got.overFired > baseline.overFired + overFireTolerance`, OR
    ///   - `got.total < baseline.total - recoveryTolerance` (corpus shrank for that intent).
    ///
    /// `recoveryTolerance` absorbs a dropped clip or minor ASR variance (typically 1).
    /// `overFireTolerance` should be 0 — any over-fire on a non-term clip is a bug.
    ///
    /// Returns `(ok: true, regressions: [])` when no regressions are found.
    /// An absent intent (present in `baseline` but missing from `got`) is always a
    /// regression — it is NOT substituted with zeros.
    static func withinBaseline(
        _ got: [String: Tally],
        baseline: [String: Tally],
        recoveryTolerance: Int,
        overFireTolerance: Int
    ) -> (ok: Bool, regressions: [String]) {
        var regressions: [String] = []
        for (intent, base) in baseline {
            guard let g = got[intent] else {
                // Absent bucket — the intent entirely disappeared.
                regressions.append(intent)
                continue
            }
            let recoveryRegressed = g.recovered < base.recovered - recoveryTolerance
            let overFireRegressed = g.overFired  > base.overFired  + overFireTolerance
            let corpusShrunk      = g.total      < base.total      - recoveryTolerance
            if recoveryRegressed || overFireRegressed || corpusShrunk {
                regressions.append(intent)
            }
        }
        return (ok: regressions.isEmpty, regressions: regressions)
    }
}
