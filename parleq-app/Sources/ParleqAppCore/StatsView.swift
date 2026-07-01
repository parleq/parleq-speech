// StatsView — the Stats sidebar section of the Parleq app shell
// (0.14.0 PR 5, #220).
//
// Four metric clusters in a 2-column grid, each showing a "today"
// big number and a "last 7 days" subtitle. Where time-series data
// is available, a tiny sparkline on the right of the card shows
// the 7-day daily trend.
//
//   Card 1 — Dictation count
//             Today, This week, sparkline of last 7 days.
//   Card 2 — Speaking time + average latencies
//             Today's spoken minutes, this week's average ASR/LLM.
//   Card 3 — Tokens + cost
//             Today's tokens + $, this week's same, per-provider
//             breakdown below.
//   Card 4 — Cleanup failure + reference-attachment rates
//             Today's % cleanup-failed and % ref-attached.
//
// Data sources: TranscriptHistory.shared (for counts, durations,
// latencies, failure / ref rates — all derivable from the in-
// memory entry list) and UsageLedger.shared (for tokens + cost,
// which TranscriptEntry doesn't track directly).
//
// All stats are computed on every body re-render. The data sets
// are small (TranscriptHistory caps at 20 entries today; usage
// ledger is a few KB), so caching isn't worth the complexity.
// SwiftUI's @ObservedObject re-render guarantees this stays in
// sync with appended entries.

import AppKit
import SwiftUI

@MainActor
struct StatsView: View {
    @ObservedObject var history: TranscriptHistory
    @ObservedObject var settingsModel: SettingsModel
    /// Collapsed by default; the user expands it to see the full
    /// usage ledger (same content as Settings → Usage) without
    /// navigating away from the Stats pane.
    @State private var usageExpanded = false
    /// Stored (not computed) so the publisher is created ONCE per view
    /// identity. A computed property would mint a fresh
    /// Timer.publish().autoconnect() on every body re-render, and
    /// `.onReceive` would re-subscribe each time — restarting the 60s
    /// interval on every render and churning Combine subscriptions.
    @State private var usageReloadTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        // Plain vertical ScrollView — same reasoning as
        // SettingsView.detailPane: a both-axes scroll gesture competes
        // with embedded controls and mis-anchors tall content so the top
        // clips. Stats has no controls, but keep it consistent and
        // top-anchored. The grid's column minimum (below) is sized to
        // fit the window's minimum width, so horizontal scroll is never
        // needed.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Stats")
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 4)

                // Fixed 2-column grid. The earlier adaptive grid
                // (.adaptive minimum 280, maximum 480) collapsed to
                // 3 columns at typical window widths, which left the
                // 4th card (Quality) orphaned on its own row while
                // the tall LLM card sat next to two short ones on
                // row 1. A fixed 2x2 keeps Dictations + Speaking
                // paired (both short, balanced heights) and LLM +
                // Quality paired (LLM is tall, Quality short — but
                // they share a row so the layout reads as two even
                // rows rather than a lopsided 3+1).
                LazyVGrid(
                    columns: [
                        // 220pt min so two columns fit within the
                        // window's minimum content width without needing
                        // horizontal scroll (2×220 + spacing + padding).
                        GridItem(.flexible(minimum: 220), spacing: 16),
                        GridItem(.flexible(minimum: 220), spacing: 16)
                    ],
                    spacing: 16
                ) {
                    dictationCountCard
                    speakingTimeCard
                    tokensCostCard
                    qualityRatesCard
                }

                Text("Stats are computed from the current session's dictation history and the on-disk usage ledger. Session counts reset on Parleq quit; the usage ledger persists in ~/.parleq/usage.jsonl.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 640)
                    .padding(.top, 8)

                // Usage ledger detail — collapsed by default so the
                // Stats pane stays focused on the session metrics
                // above. Expanding triggers a fresh ledger read so
                // the numbers are current at the moment of reveal.
                DisclosureGroup(isExpanded: $usageExpanded) {
                    UsageLedgerContent(model: settingsModel)
                        .padding(.top, 8)
                } label: {
                    // Make the whole row toggle the group, not just the chevron
                    // (clicking the small chevron directly is fiddly). The label
                    // must FILL the row width first — unlike the sidebar Settings
                    // disclosure (a List row that expands on its own), this one is
                    // in a VStack, so an intrinsic-width Text would only be tappable
                    // over the glyphs. frame(maxWidth:.infinity) + contentShape makes
                    // the whole line hit-testable; the chevron still works.
                    Text("Usage & cost")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation { usageExpanded.toggle() }
                        }
                }
                .onChange(of: usageExpanded) { _, expanded in
                    if expanded { settingsModel.refreshUsage() }
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // Read the disk usage ledger on first appearance. Cheap
            // (a few KB) but worth doing lazily so it doesn't block
            // app launch. Re-fired on the timer below to pick up
            // post-launch changes (e.g. accepting a dictation while
            // Stats is visible). Single source of truth: both this card
            // and the folded-in "Usage & cost" ledger read
            // settingsModel.usage, so a refresh/clear updates both.
            settingsModel.refreshUsage()
        }
        .onReceive(usageReloadTimer) { _ in
            settingsModel.refreshUsage()
        }
    }

    // MARK: - Cards

    private var dictationCountCard: some View {
        statsCard(title: "Dictations") {
            HStack(alignment: .firstTextBaseline) {
                bigNumber(metrics.countToday)
                Text("today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Sparkline(values: metrics.countByDayLast7)
                    .frame(width: 80, height: 28)
                    .foregroundStyle(SettingsView.brandAccent)
            }
            footerCaption("\(metrics.countWeek) this week")
        }
    }

    private var speakingTimeCard: some View {
        statsCard(title: "Speaking time") {
            HStack(alignment: .firstTextBaseline) {
                bigNumber(formatDuration(metrics.speakingMsToday))
                Text("today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Sparkline(values: metrics.speakingMsByDayLast7.map { Double($0) / 60000.0 })
                    .frame(width: 80, height: 28)
                    .foregroundStyle(SettingsView.brandAccent)
            }
            footerCaption("\(formatDuration(metrics.speakingMsWeek)) this week")
            // Render the ASR + LLM averages independently, with an
            // em-dash for the side that has no data. The earlier
            // "default to 0 ms" rendering implied an instant LLM
            // average for sessions that ran ASR but skipped cleanup
            // (no LLM configured, empty transcript, etc.).
            let latencyLine = [
                metrics.avgASRLatencyMsWeek.map { "ASR avg \($0) ms" } ?? "ASR avg —",
                metrics.avgLLMLatencyMsWeek.map { "LLM avg \($0) ms" } ?? "LLM avg —"
            ].joined(separator: " · ")
            if metrics.avgASRLatencyMsWeek != nil || metrics.avgLLMLatencyMsWeek != nil {
                footerCaption("\(latencyLine) · last 7d")
            }
        }
    }

    private var tokensCostCard: some View {
        statsCard(title: "LLM usage") {
            HStack(alignment: .firstTextBaseline) {
                bigNumber(formatTokens(settingsModel.usage.today.inputTokens + settingsModel.usage.today.outputTokens))
                Text("tokens today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatCost(settingsModel.usage.today.costUSD))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            footerCaption("\(formatTokens(settingsModel.usage.thisWeek.inputTokens + settingsModel.usage.thisWeek.outputTokens)) tokens · \(formatCost(settingsModel.usage.thisWeek.costUSD)) this week")
            if !settingsModel.usage.byModel.isEmpty {
                Divider().opacity(0.4).padding(.vertical, 2)
                // UsageLedger.byModel is currently all-time, not
                // week-scoped. Labelling it explicitly so the
                // mixed framing on this card ("today / this week"
                // big numbers + all-time breakdown) doesn't
                // mislead. A future PR can add a rolling-7-day
                // byModel breakdown to UsageAggregate if the
                // mismatch becomes visible at heavier usage.
                Text("Top models — all time")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                ForEach(settingsModel.usage.byModel.prefix(3)) { row in
                    HStack {
                        Text(row.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text("\(row.bucket.calls) call\(row.bucket.calls == 1 ? "" : "s")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var qualityRatesCard: some View {
        statsCard(title: "Quality & references") {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    bigNumber(formatPercent(metrics.refRateWeek))
                    Text("ref-attached")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("last 7 days")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    bigNumber(formatPercent(metrics.cleanupFailureRateWeek))
                    Text("cleanup-failed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("last 7 days")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Card scaffolding

    @ViewBuilder
    private func statsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsView.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SettingsView.cardBorder, lineWidth: 0.5)
        )
    }

    private func bigNumber(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 32, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .monospacedDigit()
    }

    private func bigNumber(_ value: Int) -> some View {
        bigNumber("\(value)")
    }

    private func footerCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Formatting helpers

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        if totalSeconds >= 3600 {
            let h = totalSeconds / 3600
            let m = (totalSeconds % 3600) / 60
            return "\(h)h \(m)m"
        }
        if totalSeconds >= 60 {
            let m = totalSeconds / 60
            let s = totalSeconds % 60
            return "\(m)m \(s)s"
        }
        return "\(totalSeconds)s"
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1.0 { return String(format: "$%.2f", usd) }
        if usd >= 0.01 { return String(format: "$%.3f", usd) }
        return String(format: "$%.4f", usd)
    }

    private func formatPercent(_ fraction: Double?) -> String {
        guard let f = fraction else { return "—" }
        return String(format: "%.0f%%", f * 100)
    }

    // MARK: - Metric computation

    /// Re-derived on every body evaluation from the text-free
    /// metric records (unlike `history.entries`, which is capped
    /// for memory + privacy reasons). Cheap: records are ~48
    /// bytes each and the per-render iteration is linear over
    /// just the last 7 days' worth of records.
    private var metrics: StatsMetrics {
        StatsMetrics.compute(records: history.metricsRecords)
    }

}

import Combine

/// Per-card derived metrics. Owns the per-day bucketing logic so
/// the view body stays declarative.
private struct StatsMetrics {
    var countToday: Int = 0
    var countWeek: Int = 0
    /// Today (index 6) is the rightmost bar; index 0 is 6 days ago.
    var countByDayLast7: [Double] = Array(repeating: 0, count: 7)

    var speakingMsToday: Int = 0
    var speakingMsWeek: Int = 0
    var speakingMsByDayLast7: [Int] = Array(repeating: 0, count: 7)

    var avgASRLatencyMsWeek: Int?
    var avgLLMLatencyMsWeek: Int?

    var refRateWeek: Double?
    var cleanupFailureRateWeek: Double?

    static func compute(records: [MetricsRecord]) -> StatsMetrics {
        var m = StatsMetrics()
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        // Use one shared window: "last 7 calendar days" = the start
        // of the day 6 calendar days ago, through now. Matches the
        // sparkline's per-day buckets (today is index 6, 6 days
        // ago is index 0) so the card totals and the trend chart
        // agree on the window boundary.
        let weekAgo = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var asrTotalMs = 0
        var asrCount = 0
        var llmTotalMs = 0
        var llmCount = 0
        var weekTotal = 0
        var weekRefAttached = 0
        var weekCleanupFailed = 0

        for record in records where record.timestamp >= weekAgo {
            // Today
            if record.timestamp >= startOfToday {
                m.countToday += 1
                m.speakingMsToday += record.audioDurationMs
            }
            // Week aggregates
            m.countWeek += 1
            m.speakingMsWeek += record.audioDurationMs
            weekTotal += 1
            if record.hadReference { weekRefAttached += 1 }
            if record.cleanupFailed { weekCleanupFailed += 1 }

            // Per-day buckets (last 7 days, today is index 6)
            let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: record.timestamp), to: startOfToday).day ?? 0
            if daysAgo >= 0 && daysAgo < 7 {
                let idx = 6 - daysAgo
                m.countByDayLast7[idx] += 1
                m.speakingMsByDayLast7[idx] += record.audioDurationMs
            }

            if let ms = record.asrLatencyMs {
                asrTotalMs += ms
                asrCount += 1
            }
            if let ms = record.llmLatencyMs {
                llmTotalMs += ms
                llmCount += 1
            }
        }

        if asrCount > 0 { m.avgASRLatencyMsWeek = asrTotalMs / asrCount }
        if llmCount > 0 { m.avgLLMLatencyMsWeek = llmTotalMs / llmCount }
        if weekTotal > 0 {
            m.refRateWeek = Double(weekRefAttached) / Double(weekTotal)
            m.cleanupFailureRateWeek = Double(weekCleanupFailed) / Double(weekTotal)
        }
        return m
    }
}

/// Simple sparkline — a polyline of normalized [Double] values
/// scaled into the view's bounds. Bottom-anchored; flat zero data
/// shows as a single horizontal line at the bottom.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let max = values.max() ?? 0
            let count = values.count
            Path { path in
                guard count > 1, max > 0 else {
                    path.move(to: CGPoint(x: 0, y: geo.size.height - 1))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 1))
                    return
                }
                let stepX = geo.size.width / CGFloat(count - 1)
                for (i, value) in values.enumerated() {
                    let normalized = value / max
                    let x = CGFloat(i) * stepX
                    // 1pt top margin so the highest point doesn't
                    // clip the stroke; 1pt bottom margin too.
                    let y = (1 - CGFloat(normalized)) * (geo.size.height - 2) + 1
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(lineWidth: 1.5)
            .foregroundStyle(.tint)
        }
    }
}
