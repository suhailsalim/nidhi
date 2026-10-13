import Foundation

// MARK: - Month in review (pure builder)
//
// Recombines data the app already has into a single month-end story: totals vs plan, the biggest
// category moves against a 3-month trailing average, top merchants (net of refunds), rewards,
// international spend, net-worth delta and the on-plan streak.
//
// `MonthReport.build` is deliberately **pure**: every input is injected (including `now` and the
// net-spend rule) so it never reads `Store` or calls `Date()`. That keeps the figures reproducible
// and lets the same builder drive both the full screen and the share card.

/// A dated net-worth reading. `Store.nwHistory` is a bare `[Double]` of daily samples with no dates,
/// so the UI layer re-attaches dates (newest sample = the last day the app recorded one) before
/// handing the series here. Samples are missing for every day the app wasn't opened, hence the
/// nearest-sample-≤-date lookup rather than an exact-date match.
struct NetWorthSample: Hashable {
    var date: Date
    var value: Double
}

struct MonthReport {

    // MARK: nested figures

    /// One category's spend for the month against its own 3-month trailing average.
    struct CategoryMove: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var symbol: String
        var colorHex: String
        var spent: Double
        /// Trailing average over the months of history that actually exist (0 when `isNew`).
        var average: Double
        /// How many of the 3 trailing months had data at all.
        var historyMonths: Int
        /// Fewer than 2 months of history — a delta would divide by too small an n, so we don't show one.
        var isNew: Bool { historyMonths < 2 }

        var delta: Double { isNew ? 0 : spent - average }
        var deltaPct: Double { (isNew || average <= 0) ? 0 : (spent - average) / average * 100 }
        var up: Bool { delta > 0 }

        /// "+₹4.2k vs 3-mo avg" / "New this month".
        var deltaLabel: String {
            if isNew { return "New this month" }
            if average <= 0 { return "First spend in 3 months" }
            if abs(delta) < 1 { return "Level with 3-mo avg" }
            return "\(up ? "+" : "−")\(INR.compact(abs(delta))) vs 3-mo avg"
        }
        /// Compact "+18%" / "New" — used on the share card.
        var deltaShort: String {
            if isNew || average <= 0 { return "New" }
            let p = Int(deltaPct.rounded())
            if p == 0 { return "level" }
            return "\(p > 0 ? "+" : "−")\(abs(p))%"
        }
    }

    /// Net spend at one merchant/brand for the month (debits minus refund credits).
    struct MerchantSpend: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var amount: Double
        var icon: String?          // Assets.xcassets brand mark, when known
        var refunded: Double       // refund credits netted out of `amount` (0 when none)
    }

    struct RewardTotal: Identifiable, Hashable {
        var id: String { currency }
        var currency: String       // "Reward Points" / "EDGE Miles" / "Cashback" / …
        var total: Double
    }

    struct CurrencySpend: Identifiable, Hashable {
        var id: String { currency }
        var currency: String       // original currency of the spend, e.g. "EUR"
        var amount: Double         // INR value
    }

    // MARK: fields

    var monthStart: Date
    var monthEnd: Date             // exclusive
    /// The month hasn't finished yet — the screen labels it an in-progress preview.
    var isPartial: Bool

    var txnCount: Int
    var totalSpent: Double
    /// Money put into Investment-kind categories. Reported separately because — exactly as in
    /// Plan/Insights — it is never part of `totalSpent`.
    var investedTotal: Double
    var totalIncome: Double
    var planTotal: Double
    var planPct: Int
    var underPlan: Bool
    /// Consecutive months up to and including this one that stayed within plan.
    var streakMonths: Int

    /// Every category with activity, ordered by how far it moved from its trailing average.
    var categoryMoves: [CategoryMove]
    var topMerchants: [MerchantSpend]
    var rewards: [RewardTotal]
    var internationalTotal: Double
    var internationalCount: Int
    var internationalByCurrency: [CurrencySpend]

    var netWorthStart: Double?
    var netWorthEnd: Double?

    var goalsActive: Int
    var goalsAchieved: Int
    var goalProgressPct: Int

    // MARK: derived

    var netSaved: Double { totalIncome - totalSpent }
    var isQuiet: Bool { txnCount == 0 }
    var netWorthDelta: Double? {
        guard let s = netWorthStart, let e = netWorthEnd else { return nil }
        return e - s
    }
    var netWorthDeltaPct: Double? {
        guard let s = netWorthStart, let d = netWorthDelta, s != 0 else { return nil }
        return d / abs(s) * 100
    }
    var monthLabel: String { monthStart.formatted(.dateTime.month(.wide).year()) }
    var shortMonthLabel: String { monthStart.formatted(.dateTime.month(.wide)) }
    var planLeft: Double { planTotal - totalSpent }
    /// The three biggest categories by spend — what the share card shows.
    var topCategories: [CategoryMove] {
        Array(categoryMoves.filter { $0.spent > 0 }.sorted { $0.spent > $1.spent }.prefix(3))
    }
    /// A one-line headline for the month.
    var headline: String {
        if isQuiet { return "A quiet month — no transactions recorded." }
        if planTotal <= 0 { return "Spent \(INR.compact(totalSpent)) across \(txnCount) transactions." }
        return underPlan
            ? "Spent \(INR.compact(totalSpent)) — \(INR.compact(abs(planLeft))) under plan."
            : "Spent \(INR.compact(totalSpent)) — \(INR.compact(abs(planLeft))) over plan."
    }

    // MARK: - Build

    /// Assemble the report. Every input is injected — no `Store`, no `Date()`.
    /// - Parameters:
    ///   - month: any date inside the month to report on.
    ///   - now: "today", used only to decide whether the month is still in progress.
    ///   - netSpend: the app's single net-spend rule (`Store.spendContribution`) — debits add,
    ///     refunds subtract, transfers/income contribute nothing.
    static func build(month: Date,
                      now: Date,
                      txns: [Txn],
                      categories: [BudgetCategory],
                      netWorth: [NetWorthSample],
                      goals: [Goal],
                      netSpend: (Txn) -> Double,
                      calendar: Calendar = .current) -> MonthReport {

        let cal = calendar
        let start = cal.dateInterval(of: .month, for: month)?.start ?? month
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? month

        let investmentNames = Set(categories.filter { $0.kind == .investments }.map(\.name))
        let monthTxns = txns.filter { $0.date >= start && $0.date < end }

        // Totals — mirrors Store.totalSpend / totalIncome for the same window.
        let totalSpent = max(0, monthTxns
            .filter { !investmentNames.contains($0.category) }
            .map(netSpend).reduce(0, +))
        let investedTotal = max(0, monthTxns
            .filter { investmentNames.contains($0.category) }
            .map(netSpend).reduce(0, +))
        let totalIncome = monthTxns.filter { $0.category == "Income" }.map(\.amount).reduce(0, +)
        let planTotal = categories.filter { $0.kind != .investments }.map(\.monthlyPlan).reduce(0, +)
        let planPct = planTotal > 0 ? Int((totalSpent / planTotal * 100).rounded()) : 0

        // Where the data actually begins — trailing averages must not treat pre-history months as ₹0.
        let dataStart: Date? = txns.map(\.date).min().map { cal.dateInterval(of: .month, for: $0)?.start ?? $0 }

        // Net spend across all categories for an arbitrary month offset (negative = earlier).
        func windowSpend(monthsBefore k: Int, category: String?) -> Double {
            guard let s = cal.date(byAdding: .month, value: -k, to: start),
                  let e = cal.date(byAdding: .month, value: 1, to: s) else { return 0 }
            return max(0, txns.filter {
                $0.date >= s && $0.date < e
                    && (category == nil ? !investmentNames.contains($0.category) : $0.category == category!)
            }.map(netSpend).reduce(0, +))
        }
        /// Whether a month `k` before the report month is inside the recorded history.
        func hasHistory(monthsBefore k: Int) -> Bool {
            guard let dataStart, let s = cal.date(byAdding: .month, value: -k, to: start) else { return false }
            return s >= dataStart
        }

        // MARK: category moves vs 3-month trailing average
        var moves: [CategoryMove] = []
        for c in categories where c.kind != .investments {   // investments aren't spend — see investedTotal
            let spent = max(0, monthTxns.filter { $0.category == c.name }.map(netSpend).reduce(0, +))
            var sum = 0.0, n = 0
            for k in 1...3 where hasHistory(monthsBefore: k) {
                sum += windowSpend(monthsBefore: k, category: c.name); n += 1
            }
            let avg = n > 0 ? sum / Double(n) : 0
            guard spent > 0 || avg > 0 else { continue }
            moves.append(CategoryMove(name: c.name, symbol: c.symbol, colorHex: c.color,
                                      spent: spent, average: avg, historyMonths: n))
        }
        moves.sort { a, b in
            if a.isNew != b.isNew { return !a.isNew }          // real moves first, "new" after
            if abs(a.delta) != abs(b.delta) { return abs(a.delta) > abs(b.delta) }
            return a.spent > b.spent
        }

        // MARK: top merchants — net per brand, so a refund cancels its own purchase
        var gross: [String: Double] = [:]      // net amount per brand (debits − refund credits)
        var refunds: [String: Double] = [:]
        var icons: [String: String] = [:]
        for t in monthTxns {
            guard !t.transfer, t.category != "Transfer", t.category != "Income",
                  !investmentNames.contains(t.category) else { continue }
            let c = netSpend(t)
            guard c != 0 else { continue }
            let classified = BrandCatalog.classify([t.merchant, t.counterparty ?? ""].joined(separator: " "))
            let key = classified.brand ?? t.merchant
            gross[key, default: 0] += c
            if c < 0 { refunds[key, default: 0] += abs(c) }
            if icons[key] == nil, let i = classified.icon { icons[key] = i }
        }
        let topMerchants = gross
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }   // stable order for ties
            .prefix(5)
            .map { MerchantSpend(name: $0.key, amount: $0.value, icon: icons[$0.key], refunded: refunds[$0.key] ?? 0) }

        // MARK: rewards + international (same rules as InsightsView)
        var rewardMap: [String: Double] = [:]
        for t in monthTxns where (t.reward ?? 0) != 0 {
            rewardMap[t.rewardCurrency ?? "Reward", default: 0] += (t.reward ?? 0)
        }
        let rewards = rewardMap
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { RewardTotal(currency: $0.key, total: $0.value) }

        let intl = monthTxns.filter { $0.isInternational && !$0.transfer && $0.amount < 0 }
        var fxMap: [String: Double] = [:]
        for t in intl {
            let c = (t.forexCurrency?.isEmpty == false) ? t.forexCurrency! : "Other"
            fxMap[c, default: 0] += abs(t.amount)
        }
        let byCurrency = fxMap
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { CurrencySpend(currency: $0.key, amount: $0.value) }

        // MARK: net worth — nearest sample at or before each edge (the series has gaps)
        let series = netWorth.sorted { $0.date < $1.date }
        func sample(atOrBefore d: Date) -> Double? { series.last { $0.date <= d }?.value }
        let endEdge = min(end.addingTimeInterval(-1), now)
        let nwStart = sample(atOrBefore: start)
        let nwEnd = endEdge >= start ? sample(atOrBefore: endEdge) : nil

        // MARK: on-plan streak ending at this month
        var streak = 0
        if planTotal > 0 {
            var k = 0
            while k < 60 {
                guard hasHistory(monthsBefore: k) else { break }
                let s = windowSpend(monthsBefore: k, category: nil)
                let pct = s / planTotal * 100
                if pct > 0 && pct <= 100 { streak += 1; k += 1 } else { break }
            }
        }

        // MARK: goals snapshot (progress only — never shared)
        let active = goals.filter(\.active)
        let targetSum = active.map(\.target).reduce(0, +)
        let savedSum = active.map(\.saved).reduce(0, +)

        return MonthReport(
            monthStart: start,
            monthEnd: end,
            isPartial: now < end,
            txnCount: monthTxns.count,
            totalSpent: totalSpent,
            investedTotal: investedTotal,
            totalIncome: totalIncome,
            planTotal: planTotal,
            planPct: planPct,
            underPlan: planTotal > 0 && totalSpent <= planTotal,
            streakMonths: streak,
            categoryMoves: moves,
            topMerchants: Array(topMerchants),
            rewards: rewards,
            internationalTotal: intl.reduce(0) { $0 + abs($1.amount) },
            internationalCount: intl.count,
            internationalByCurrency: byCurrency,
            netWorthStart: nwStart,
            netWorthEnd: nwEnd,
            goalsActive: active.count,
            goalsAchieved: goals.filter { $0.status == .achieved }.count,
            goalProgressPct: targetSum > 0 ? Int(min(100, savedSum / targetSum * 100).rounded()) : 0
        )
    }

    // MARK: - Month list

    /// Month starts with data, newest first: this month (in progress) down to the oldest month that
    /// has a transaction. Empty when there are no transactions at all.
    static func availableMonths(txns: [Txn], now: Date, calendar: Calendar = .current) -> [Date] {
        guard let oldest = txns.map(\.date).min() else { return [] }
        let cal = calendar
        guard let first = cal.dateInterval(of: .month, for: oldest)?.start,
              let current = cal.dateInterval(of: .month, for: now)?.start else { return [] }
        var out: [Date] = []
        var m = current
        while m >= first && out.count < 60 {
            out.append(m)
            guard let prev = cal.date(byAdding: .month, value: -1, to: m) else { break }
            m = prev
        }
        return out
    }

    /// The most recent *completed* month (nil when there's no data for it).
    static func lastCompleteMonth(txns: [Txn], now: Date, calendar: Calendar = .current) -> Date? {
        let cal = calendar
        guard let current = cal.dateInterval(of: .month, for: now)?.start,
              let prev = cal.date(byAdding: .month, value: -1, to: current) else { return nil }
        return availableMonths(txns: txns, now: now, calendar: cal).contains(prev) ? prev : nil
    }

    // MARK: - AI closing note (opt-in only)

    /// Month-level aggregates for an optional AI closing paragraph. Same *kind* of data
    /// `AIInsights.summary` already sends — totals and category figures, never merchant rows,
    /// account names, balances or raw transactions.
    var aggregateBlock: String {
        var L: [String] = ["## \(monthLabel) totals"]
        L.append("Spent ₹\(Int(totalSpent)) of ₹\(Int(planTotal)) planned (\(planPct)%), \(txnCount) transactions.")
        if totalIncome > 0 { L.append("Income credited ₹\(Int(totalIncome)); net ₹\(Int(netSaved)).") }
        if investedTotal > 0 { L.append("Invested ₹\(Int(investedTotal)) (not counted as spend).") }
        L.append("On-plan streak: \(streakMonths) month\(streakMonths == 1 ? "" : "s").")
        let top = categoryMoves.prefix(6)
        if !top.isEmpty {
            L.append("\n### Category moves vs 3-month average")
            for m in top {
                L.append(m.isNew
                         ? "- \(m.name): ₹\(Int(m.spent)) (new — no history)"
                         : "- \(m.name): ₹\(Int(m.spent)) vs avg ₹\(Int(m.average)) (\(m.deltaShort))")
            }
        }
        return L.joined(separator: "\n")
    }

    /// Instruction for the closing paragraph. Combined with `AIInsights.summary` by the view.
    var aiInstruction: String {
        """
        Write a short closing paragraph (3-4 sentences, no headers, no bullets) for my \(monthLabel) \
        month-in-review. Say what actually happened this month, name the one or two categories that \
        moved most and why that matters, and end with one concrete thing to watch next month. Use the \
        numbers given. Do not invent figures.
        """
    }
}
