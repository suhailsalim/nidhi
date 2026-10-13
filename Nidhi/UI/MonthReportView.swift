import SwiftUI
import UIKit

// MARK: - Month in review (UI)
//
// The screen for one month's report plus its two entry points (Insights card, Home banner) and the
// share card. Everything here is a thin reader over `MonthReport.build` — no figures are computed
// in the views.
//
// Privacy: `MonthReportShareView` is a *separate, deliberately minimal* view. It carries only the
// month, the total spent, three category names with percentage deltas, the on-plan streak and
// reward totals. No balances, no net worth, no account or card names, no merchants. The scroll view
// below may show more; the share image never does.

// MARK: - Store bridge

extension Store {
    /// Re-attach dates to `nwHistory` (a bare daily series) so the report can do a
    /// nearest-sample-≤-date lookup. The newest sample belongs to the last day the app recorded
    /// one; earlier samples step back a day each. Gaps (app not opened) shift the whole tail
    /// earlier, which is exactly why the report never does an exact-date match.
    var netWorthSamples: [NetWorthSample] {
        guard !nwHistory.isEmpty else { return [] }
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let last = UserDefaults.standard.string(forKey: "nidhi_nw_day").flatMap { f.date(from: $0) } ?? Date()
        let lastDay = cal.startOfDay(for: last)
        let n = nwHistory.count
        return nwHistory.enumerated().compactMap { i, v in
            guard let d = cal.date(byAdding: .day, value: -(n - 1 - i), to: lastDay) else { return nil }
            return NetWorthSample(date: d, value: v)
        }
    }

    /// Build the month-in-review report for the month containing `month`.
    func monthReport(for month: Date, now: Date = Date()) -> MonthReport {
        MonthReport.build(month: month, now: now, txns: txns, categories: categories,
                          netWorth: netWorthSamples, goals: goals,
                          netSpend: { self.spendContribution($0) })
    }
}

// MARK: - Entry point: Insights card

/// "June in review →" with a picker for any month that has data.
struct MonthReportEntryCard: View {
    @EnvironmentObject var store: Store
    @State private var selected: Date?
    @State private var showing = false

    private var months: [Date] { MonthReport.availableMonths(txns: store.txns, now: Date()) }
    private var currentMonth: Date? { Calendar.current.dateInterval(of: .month, for: Date())?.start }
    private var month: Date? {
        selected ?? MonthReport.lastCompleteMonth(txns: store.txns, now: Date()) ?? months.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Month in review")
                if months.count > 1, let month {
                    Menu {
                        ForEach(months, id: \.self) { m in
                            Button { selected = m } label: {
                                Text(label(m) + (m == currentMonth ? " · in progress" : ""))
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(label(month)).font(.caption.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .foregroundStyle(Zen.accentDeep)
                    }
                }
            }

            if let month {
                Button { showing = true } label: {
                    HStack(spacing: 12) {
                        IconChip(symbol: "doc.text.magnifyingglass", tint: Zen.accentDeep)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("\(label(month)) in review")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                                if month == currentMonth {
                                    Text("In progress").font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(Zen.accent.opacity(0.16)))
                                        .foregroundStyle(Zen.accentDeep)
                                }
                            }
                            Text("Totals, category moves, top merchants — shareable")
                                .font(.caption2).foregroundStyle(Zen.ink3).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Zen.ink3)
                    }
                }.buttonStyle(.plain)
            } else {
                Text("Import a statement or add a transaction to get your first monthly report.")
                    .font(.caption).foregroundStyle(Zen.ink3)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
        .sheet(isPresented: $showing) {
            if let month { NavigationStack { MonthReportView(month: month) } }
        }
    }

    private func label(_ d: Date) -> String { d.formatted(.dateTime.month(.wide).year()) }
}

// MARK: - Entry point: Home banner (first 5 days of a month)

/// A one-tap nudge to last month's report, shown only in the first 5 days of a new month and only
/// when last month actually has data. The caller gates on `dueMonth(_:)` so nothing — not even an
/// empty, spacing-consuming child — is added to Home the rest of the time.
struct MonthReviewBanner: View {
    var lastMonth: Date
    @State private var showing = false

    /// The month to nudge about, or nil when the banner shouldn't appear at all.
    static func dueMonth(_ store: Store, now: Date = Date()) -> Date? {
        guard Calendar.current.component(.day, from: now) <= 5 else { return nil }
        return MonthReport.lastCompleteMonth(txns: store.txns, now: now)
    }

    var body: some View {
            Button { showing = true } label: {
                HStack(spacing: 12) {
                    IconChip(symbol: "calendar.badge.checkmark", tint: Zen.greenDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(lastMonth.formatted(.dateTime.month(.wide))) in review is ready")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                        Text("See how the month went — totals, category moves, rewards")
                            .font(.caption2).foregroundStyle(Zen.ink2).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Zen.ink3)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zenCard(tinted: Zen.green, 20)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showing) {
                NavigationStack { MonthReportView(month: lastMonth) }
            }
    }
}

// MARK: - The report screen

struct MonthReportView: View {
    var month: Date
    @EnvironmentObject var store: Store
    @EnvironmentObject var ai: AIManager
    @Environment(\.dismiss) private var dismiss

    @State private var shareImage: Image?
    @State private var note: String?
    @State private var noteRunning = false
    @State private var noteError: String?
    /// Built once per month (the figures are historical) rather than on every body pass.
    @State private var report: MonthReport?

    var body: some View {
        ZStack {
            ZenBackground()
            ScrollView {
                if let r = report {
                VStack(spacing: 20) {
                    headerCard(r)
                    if r.isQuiet {
                        EmptyState(icon: "moon.zzz",
                                   title: "A quiet month",
                                   message: "No transactions recorded for \(r.monthLabel). Import a statement for this period to fill it in.")
                    } else {
                        categoriesCard(r)
                        merchantsCard(r)
                        if !r.rewards.isEmpty || r.internationalCount > 0 { rewardsCard(r) }
                        netWorthCard(r)
                        if r.goalsActive > 0 || r.goalsAchieved > 0 { goalsCard(r) }
                        aiCard(r)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
                } else {
                    ProgressView().padding(.top, 60)
                }
            }
        }
        .navigationTitle("Month in review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let shareImage, let r = report {
                    ShareLink(item: shareImage,
                              preview: SharePreview("\(r.monthLabel) in review", image: shareImage)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .task(id: month) {
            let r = store.monthReport(for: month)
            report = r
            note = nil; noteError = nil
            renderShareImage(r)
        }
    }

    // MARK: header
    private func headerCard(_ r: MonthReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(r.monthLabel.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
                if r.isPartial {
                    Text("In progress").font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Zen.accent.opacity(0.18)))
                        .foregroundStyle(Zen.accentDeep)
                }
                Spacer()
            }
            Text(INR.compact(r.totalSpent))
                .font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(Zen.ink)
                .padding(.top, 2)
            Text(r.headline).font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2).padding(.top, 2)

            if r.planTotal > 0 {
                VStack(spacing: 7) {
                    HStack {
                        Label("Against plan", systemImage: "chart.pie").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
                        Spacer()
                        Text("\(r.planPct)% of \(INR.compact(r.planTotal))").font(.caption.weight(.bold)).foregroundStyle(Zen.ink)
                    }
                    ZenBar(value: r.planTotal > 0 ? r.totalSpent / r.planTotal : 0,
                           tint: AnyShapeStyle(r.underPlan ? Zen.green : Zen.caution))
                }
                .padding(.top, 16)
            }

            HStack(spacing: 10) {
                miniStat("Transactions", "\(r.txnCount)", "list.bullet")
                if r.totalIncome > 0 { miniStat("Income", INR.compact(r.totalIncome), "arrow.down.left") }
                if r.investedTotal > 0 { miniStat("Invested", INR.compact(r.investedTotal), "chart.line.uptrend.xyaxis") }
                miniStat("On-plan streak", "\(r.streakMonths) mo", "flame.fill")
            }
            .padding(.top, 16)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .zenCard(tinted: r.underPlan ? Zen.green : Zen.accent, 30)
    }

    private func miniStat(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: symbol).font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink3)
                .labelStyle(.titleAndIcon).lineLimit(1)
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: category moves
    private func categoriesCard(_ r: MonthReport) -> some View {
        let moves = Array(r.categoryMoves.prefix(6))
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Biggest moves")
            if moves.isEmpty {
                Text("No category spending this month.").font(.caption).foregroundStyle(Zen.ink3)
            } else {
                ForEach(moves) { m in
                    HStack(spacing: 12) {
                        IconChip(symbol: m.symbol, size: 34, tint: Color(hex: m.colorHex))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink).lineLimit(1)
                            Text(m.deltaLabel).font(.caption2).foregroundStyle(m.isNew ? Zen.ink3 : (m.up ? Zen.caution : Zen.greenDeep))
                        }
                        Spacer(minLength: 4)
                        Text(INR.compact(m.spent)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                    }
                }
                Text("Compared with each category's average over the previous 3 months. Categories without at least 2 months of history are marked new.")
                    .font(.caption2).foregroundStyle(Zen.ink3)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }

    // MARK: top merchants
    private func merchantsCard(_ r: MonthReport) -> some View {
        let maxV = r.topMerchants.map(\.amount).max() ?? 1
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Top merchants")
            if r.topMerchants.isEmpty {
                Text("No merchant spending this month.").font(.caption).foregroundStyle(Zen.ink3)
            } else {
                ForEach(r.topMerchants) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            IconChip(symbol: "bag", brandIcon: m.icon, size: 26)
                            Text(m.name).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink).lineLimit(1)
                            Spacer()
                            Text(INR.compact(m.amount)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                        }
                        ZenBar(value: maxV > 0 ? m.amount / maxV : 0, tint: AnyShapeStyle(Zen.accent))
                        if m.refunded > 0 {
                            Text("net of \(INR.compact(m.refunded)) refunded").font(.caption2).foregroundStyle(Zen.greenDeep)
                        }
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }

    // MARK: rewards + international
    private func rewardsCard(_ r: MonthReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Rewards & abroad")
            ForEach(r.rewards) { rw in
                HStack {
                    Label(rw.currency, systemImage: "star.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.greenDeep)
                    Spacer()
                    Text("+\(NumberFormatter.localizedString(from: NSNumber(value: rw.total), number: .decimal))")
                        .font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                }
            }
            if r.internationalCount > 0 {
                if !r.rewards.isEmpty { Divider().opacity(0.4) }
                HStack {
                    Label("International spend", systemImage: "globe").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                    Spacer()
                    Text(INR.compact(r.internationalTotal)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                }
                if !r.internationalByCurrency.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(r.internationalByCurrency) { c in
                                Text("\(c.currency) · \(INR.compact(c.amount))").font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Zen.accent.opacity(0.14))).foregroundStyle(Zen.accentDeep)
                            }
                        }
                    }
                }
                Text("\(r.internationalCount) transaction\(r.internationalCount == 1 ? "" : "s") abroad")
                    .font(.caption2).foregroundStyle(Zen.ink3)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }

    // MARK: net worth
    private func netWorthCard(_ r: MonthReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Net worth")
            if let delta = r.netWorthDelta, let start = r.netWorthStart, let end = r.netWorthEnd {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold)).foregroundStyle(delta >= 0 ? Zen.greenDeep : Zen.caution)
                    Text(INR.compact(delta)).font(.title2.weight(.bold)).foregroundStyle(Zen.ink)
                    if let pct = r.netWorthDeltaPct {
                        Text(String(format: "%@%.1f%%", pct >= 0 ? "+" : "", pct))
                            .font(.caption.weight(.bold)).foregroundStyle(delta >= 0 ? Zen.greenDeep : Zen.caution)
                    }
                    Spacer()
                }
                Text("\(INR.compact(start)) → \(INR.compact(end)) over \(r.shortMonthLabel)")
                    .font(.caption).foregroundStyle(Zen.ink3)
            } else {
                Text("Net-worth history doesn't reach back to this month yet — the app keeps the last 90 daily samples.")
                    .font(.caption).foregroundStyle(Zen.ink3)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }

    // MARK: goals
    private func goalsCard(_ r: MonthReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Goals")
            HStack {
                Text("\(r.goalsActive) active\(r.goalsAchieved > 0 ? " · \(r.goalsAchieved) achieved" : "")")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                Spacer()
                Text("\(r.goalProgressPct)%").font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
            }
            ZenBar(value: Double(r.goalProgressPct) / 100, tint: AnyShapeStyle(Zen.calmGradient))
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }

    // MARK: optional AI closing note — absent entirely when AI is off
    @ViewBuilder private func aiCard(_ r: MonthReport) -> some View {
        if ai.enabled && ai.isConfigured {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Zen.accentDeep)
                    Text("Closing note").font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                    Spacer()
                    Text(ai.provider.label).font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink3)
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(Zen.ink2).textSelection(.enabled)
                    Text("AI-generated · verify important numbers.").font(.caption2).foregroundStyle(Zen.ink3)
                } else if let noteError {
                    Label(noteError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Zen.caution)
                } else {
                    Text("Send this month's aggregates to \(ai.provider.label) for a short written summary. Nothing else leaves the device.")
                        .font(.caption).foregroundStyle(Zen.ink3)
                }
                Button { writeNote(r) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "text.quote").font(.caption)
                        Text(note == nil ? "Write a closing note" : "Rewrite").font(.caption.weight(.semibold))
                        if noteRunning { ProgressView().controlSize(.mini) }
                    }
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(Zen.accent.opacity(0.14)), in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain).foregroundStyle(Zen.ink).disabled(noteRunning)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).zenCard(tinted: Zen.accent, 24)
        }
    }

    private func writeNote(_ r: MonthReport) {
        noteRunning = true; noteError = nil
        Task {
            do {
                note = try await ai.complete(
                    system: AIInsights.system,
                    user: "\(r.aiInstruction)\n\n\(r.aggregateBlock)\n\n\(AIInsights.summary(store))")
            } catch {
                noteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            noteRunning = false
        }
    }

    // MARK: share image
    /// Renders the *share-safe* card (not this scroll view) at a fixed 360-pt design width; the
    /// explicit frame + scale is what keeps the exported PNG crisp and correctly sized (≥1080 px).
    @MainActor private func renderShareImage(_ r: MonthReport) {
        let renderer = ImageRenderer(content: MonthReportShareView(report: r).frame(width: 360))
        renderer.scale = max(UIScreen.main.scale, 3)
        renderer.isOpaque = true
        if let ui = renderer.uiImage { shareImage = Image(uiImage: ui) }
    }
}

// MARK: - Share card (share-safe by design)

/// The ONLY thing that ever leaves the app as an image. Contains: month, total spent, top three
/// categories with percentage deltas, on-plan streak, reward totals. Deliberately excludes account
/// names, masks, balances, net worth, goals and merchant names.
///
/// No Liquid Glass here — `ImageRenderer` rasterises plain fills reliably; glass effects do not.
struct MonthReportShareView: View {
    var report: MonthReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(report.monthLabel.uppercased())
                .font(.system(size: 13, weight: .bold)).tracking(1.4)
                .foregroundStyle(.white.opacity(0.75))
            Text("Month in review")
                .font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .padding(.top, 1)

            Text("SPENT").font(.system(size: 11, weight: .bold)).tracking(1.2)
                .foregroundStyle(.white.opacity(0.7)).padding(.top, 22)
            Text(INR.compact(report.totalSpent))
                .font(.system(size: 44, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            if report.planTotal > 0 {
                Text("\(report.planPct)% of plan · \(report.underPlan ? "under" : "over") by \(INR.compact(abs(report.planLeft)))")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 2)
            }

            if !report.topCategories.isEmpty {
                Text("TOP CATEGORIES").font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7)).padding(.top, 22)
                VStack(spacing: 8) {
                    ForEach(report.topCategories) { c in
                        HStack(spacing: 10) {
                            Image(systemName: c.symbol).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white).frame(width: 22)
                            Text(c.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(c.deltaShort)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(.white.opacity(0.18)))
                        }
                    }
                }
                .padding(.top, 8)
            }

            HStack(spacing: 10) {
                chip("\(report.streakMonths) mo on plan", "flame.fill")
                ForEach(report.rewards.prefix(2)) { r in
                    chip("+\(NumberFormatter.localizedString(from: NSNumber(value: r.total), number: .decimal)) \(r.currency)", "star.fill")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 22)

            Text("Nidhi · figures only, no account details")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .padding(.top, 22)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Zen.accentDeep, Zen.accent, Zen.green],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 12, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.2)))
    }
}
