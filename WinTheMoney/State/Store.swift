import SwiftUI
import Combine
import WidgetKit

/// Single source of truth. No mock data: the app starts empty and is populated from
/// manual entry, PDF statement imports, or a connected Account Aggregator. Derived
/// stats (level, streak, milestones, badges, plan history) are computed from real data.
final class Store: ObservableObject {
    @Published var tab: Tab = .home

    @Published var categories: [BudgetCategory] = []
    @Published var txns: [Txn] = [] { didSet { searchBlobs.removeAll(keepingCapacity: true) } }
    @Published var banks: [BankAccount] = []
    @Published var cards: [CreditCard] = []
    @Published var deposits: [Deposit] = []
    @Published var goals: [Goal] = []
    @Published var milestones: [Milestone] = []
    @Published var badges: [Badge] = []
    @Published var investments: [Investment] = []
    /// Borrowings (home/car/personal…). Derived surface lives in `Store+Loans.swift`.
    @Published var loans: [Loan] = []

    // statement ingestion ledger + the conflicts queue (rows a parser couldn't fully resolve)
    @Published var statements: [StatementRecord] = []
    @Published var conflicts: [DataConflict] = []

    // income & tax
    @Published var incomeStreams: [IncomeStream] = []
    @Published var taxProfile = TaxProfile()              // inputs for the slab-based estimate
    @Published var payslips: [Payslip] = []               // imported/entered salary slips
    @Published var advanceTaxPaidStages: Set<Int> = []   // which of the 4 instalments are marked paid

    /// Learned merchant/counterparty → category name (auto-applied on import).
    @Published var merchantRules: [String: String] = [:]
    /// Recurring group keys the user muted ("not a subscription"). Muted groups stay listed but
    /// drop out of upcoming charges, burn totals and notifications.
    @Published var mutedRecurringKeys: Set<String> = []

    // live FX rates (currency → INR), persisted & refreshed
    @Published var fxRates: [String: Double] = ["INR": 1]

    // net worth history (one point per day, built from real balances)
    @Published var nwHistory: [Double] = []

    @Published var userName: String = UserDefaults.standard.string(forKey: "wtm_user_name") ?? "" {
        didSet { UserDefaults.standard.set(userName, forKey: "wtm_user_name") }
    }
    @Published var netWorthTarget: Double = (UserDefaults.standard.object(forKey: "wtm_nw_target") as? Double) ?? 5_000_000 {
        didSet { UserDefaults.standard.set(netWorthTarget, forKey: "wtm_nw_target") }
    }
    /// When true, all Account Aggregator UI is hidden — statement upload + manual only.
    @Published var preferStatementImport: Bool = UserDefaults.standard.bool(forKey: "wtm_prefer_statement") {
        didSet { UserDefaults.standard.set(preferStatementImport, forKey: "wtm_prefer_statement") }
    }
    /// Account Aggregator (Setu) is OFF unless the user explicitly opts in. No sync ever runs otherwise.
    @Published var accountAggregatorEnabled: Bool = UserDefaults.standard.bool(forKey: "wtm_aa_enabled") {
        didSet { UserDefaults.standard.set(accountAggregatorEnabled, forKey: "wtm_aa_enabled") }
    }
    @Published var notificationsEnabled: Bool = UserDefaults.standard.bool(forKey: "wtm_notifs") {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "wtm_notifs") }
    }
    @Published var autoBackupEnabled: Bool = (UserDefaults.standard.object(forKey: "wtm_autobackup") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: "wtm_autobackup") }
    }

    /// Write a backup now (Files + iCloud Drive when available). Returns where it landed.
    /// A manual backup is never blocked by the shrink gate — the user asked for it — but it says so.
    @discardableResult
    func backupNow() -> String {
        let shrinking = backupWouldShrink()
        let where_ = BackupManager.write(exportBundle())
        guard shrinking, where_ != "—" else { return where_ }
        return "\(where_) — warning: far fewer transactions than the last backup"
    }

    /// The auto-backup safety gate. The rule is deliberately dumb and transparent: if the previous
    /// backup held more than 20 transactions and we're about to write fewer than 25% of that, the
    /// live store has almost certainly been wiped or failed to decode — keep the old backups.
    /// Returns false when there's no previous backup to compare against.
    func backupWouldShrink() -> Bool {
        guard let old = BackupManager.latestData(), let s = previewBackup(old) else { return false }
        return s.txns > 20 && Double(txns.count) < Double(s.txns) * 0.25
    }

    /// Called on launch and when the app backgrounds.
    func autoBackupIfEnabled() {
        guard autoBackupEnabled, hasData, !backupWouldShrink() else { return }
        _ = backupNow()
    }

    /// Restore the most recent auto-backup; returns success.
    @discardableResult
    func restoreLatestBackup() -> Bool {
        guard let data = BackupManager.latestData() else { return false }
        return restore(data)
    }

    /// Restore one specific backup file from the rotation.
    @discardableResult
    func restoreBackup(_ info: BackupManager.BackupInfo) -> Bool {
        guard let data = BackupManager.data(at: info.url) else { return false }
        return restore(data)
    }

    /// Shared restore path: snapshot the state we're about to destroy first, then replace.
    private func restore(_ data: Data) -> Bool {
        if hasData { BackupManager.write(exportBundle(), preRestore: true) }
        return importBundle(data, replace: true)
    }

    /// What a backup file holds, for the restore preview. nil when the file doesn't decode.
    struct BackupSummary {
        var exportedAt: Date
        var txns = 0, banks = 0, cards = 0, deposits = 0, goals = 0, investments = 0
        var firstTxn: Date?
        var lastTxn: Date?
    }

    /// Decodes through the same tolerant `BackupBundle` path `importBundle` uses — never a second decoder.
    func previewBackup(_ data: Data) -> BackupSummary? {
        guard let b = try? Self.backupCoder.1.decode(BackupBundle.self, from: data) else { return nil }
        let p = b.data
        let dates = p.txns.map(\.date).sorted()
        return BackupSummary(exportedAt: b.exportedAt, txns: p.txns.count, banks: p.banks.count,
                             cards: p.cards.count, deposits: p.deposits.count, goals: p.goals.count,
                             investments: p.investments.count, firstTxn: dates.first, lastTxn: dates.last)
    }

    var targetLabel: String { INR.compact(netWorthTarget) }

    private let key = "win_the_money_v1"
    private let nwDayKey = "wtm_nw_day"

    init() {
        load()
        if let t = ProcessInfo.processInfo.environment["WTM_TAB"], let forced = Tab(rawValue: t) { tab = forced }
        // One-time retroactive re-categorisation when the brand library version bumps.
        // v3: Tax category + direct-tax (CBDT/income tax) and indirect-tax (GST/CBIC/customs)
        // rules — moves past tax debits out of "Other".
        let catLibVersion = 3
        if UserDefaults.standard.integer(forKey: "wtm_cat_lib_v") < catLibVersion, !txns.isEmpty {
            recategorizeAll()
        }
        UserDefaults.standard.set(catLibVersion, forKey: "wtm_cat_lib_v")
        publishSnapshot()
        Task { await refreshFX() }
    }

    // MARK: derived totals
    var investmentsTotal: Double { investments.map(\.currentValue).reduce(0,+) }
    var liquidNetWorth: Double { banks.map(\.balance).reduce(0,+) + deposits.map(\.current).reduce(0,+) + investmentsTotal }
    var totalTracked: Double { liquidNetWorth - cards.map(\.outstanding).reduce(0,+) }
    var nwChange: Double { nwHistory.count >= 2 ? nwHistory.last! - nwHistory[nwHistory.count-2] : 0 }
    var nwChangePct: Double {
        guard nwHistory.count >= 2, nwHistory[nwHistory.count-2] != 0 else { return 0 }
        return nwChange / nwHistory[nwHistory.count-2] * 100
    }
    var toTarget: Double { max(0, netWorthTarget - liquidNetWorth) }
    var toTargetPct: Int { netWorthTarget > 0 ? Int(min(100, liquidNetWorth / netWorthTarget * 100)) : 0 }

    var spentTotal: Double { monthSpend(monthsAgo: 0) }
    /// Sum of caps normalised to per-month, so quarterly/annual caps fold into the monthly overview.
    /// Excludes Investment-kind categories — they have their own cap/progress bar but aren't "spend".
    var planTotal: Double { categories.filter { $0.kind != .investments }.map(\.monthlyPlan).reduce(0,+) }
    var planLeft: Double { planTotal - spentTotal }
    var planPct: Int { planTotal > 0 ? Int((spentTotal/planTotal*100).rounded()) : 0 }
    var top3: [BudgetCategory] { Array(categories.sorted { $0.spent > $1.spent }.prefix(3)) }
    var recent: [Txn] { Array(txns.sorted { $0.date > $1.date }.prefix(5)) }

    var banksTotal: Double { banks.map(\.balance).reduce(0,+) }
    var cardsTotal: Double { cards.map(\.outstanding).reduce(0,+) }
    var depositsTotal: Double { deposits.map(\.current).reduce(0,+) }

    var hasData: Bool { !banks.isEmpty || !txns.isEmpty || !deposits.isEmpty || !cards.isEmpty }

    var segments: [Segment] {
        [ Segment(label: "Bank balances", value: banksTotal, colorHex: "6E9BD8"),
          Segment(label: "Investments", value: investmentsTotal, colorHex: "5BA585"),
          Segment(label: "FD & RD", value: depositsTotal, colorHex: "7FC4A3"),
          Segment(label: "Credit owed", value: -cardsTotal, colorHex: "9AA7BE"),
          Segment(label: "Loans", value: -loansOutstanding, colorHex: "7C8AA5") ]
            .filter { $0.value != 0 }
    }

    // MARK: income & tax (multi-currency; converted to INR via live FX)
    func fxRate(_ currency: String) -> Double {
        currency == "INR" ? 1 : (fxRates[currency] ?? Currencies.fallbackINR[currency] ?? 1)
    }
    func inrAnnual(_ s: IncomeStream) -> Double { s.annual * fxRate(s.currency) }
    func bankName(_ id: UUID?) -> String? { id.flatMap { i in banks.first { $0.id == i }?.name } }
    var grossIncome: Double { incomeStreams.map { inrAnnual($0) }.reduce(0,+) }

    /// The slab-based tax estimate for the current profile (both regimes + recommendation).
    var tax: TaxComputation { TaxEngine.compute(taxProfile, fyStreamsSalary: grossIncome) }
    var taxTotal: Double { tax.totalTax }

    func updateTaxProfile(_ p: TaxProfile) { taxProfile = p; save() }
    func addPayslip(_ s: Payslip) { payslips.insert(s, at: 0); applyPayslipsToProfile(); save() }
    func remove(payslip: Payslip) { payslips.removeAll { $0.id == payslip.id }; applyPayslipsToProfile(); save() }

    /// Roll up imported payslips into the salary track: project annual gross from the slips' average
    /// and sum their TDS. Only fills figures the user hasn't manually overridden to non-zero values.
    func applyPayslipsToProfile() {
        guard !payslips.isEmpty else { return }
        let months = Double(payslips.count)
        let avgGross = payslips.map(\.grossEarnings).reduce(0,+) / max(1, months)
        var p = taxProfile
        if p.track == .selfEmployed || p.track == .business { p.track = .mixed }   // they have salary now
        else if p.track == .salaried || p.grossSalary == 0 { /* salaried stays */ }
        p.grossSalary = max(p.grossSalary, (avgGross * 12).rounded())   // projected annual
        p.tdsPaid = payslips.map(\.tds).reduce(0,+)                     // YTD TDS from slips
        let pf = payslips.map(\.pf).reduce(0,+)
        if p.ded80C < pf { p.ded80C = min(150_000, pf * (12 / max(1, months))) }   // PF is 80C-eligible (projected)
        p.seeded = true
        taxProfile = p
    }
    /// Advance-tax instalment cumulative percentages (15/45/75/100).
    static let advancePcts: [Double] = [0.15, 0.45, 0.75, 1.0]
    /// Derived from which instalments are marked paid.
    var taxPaid: Double {
        advanceTaxPaidStages.reduce(0.0) { acc, i in
            guard i >= 0, i < Self.advancePcts.count else { return acc }
            let prev = i == 0 ? 0 : Self.advancePcts[i - 1]
            return acc + (Self.advancePcts[i] - prev) * taxTotal
        }
    }
    var taxPending: Double { max(0, taxTotal - taxPaid) }
    var taxPaidPct: Int { taxTotal > 0 ? Int((taxPaid/taxTotal*100).rounded()) : 0 }
    func toggleAdvanceStage(_ i: Int) {
        if advanceTaxPaidStages.contains(i) { advanceTaxPaidStages.remove(i) } else { advanceTaxPaidStages.insert(i) }
        save()
    }
    /// ITR due = 31 Jul of the assessment year (year after the current FY's March end).
    var filingDue: String {
        let cal = Calendar.current, now = Date()
        let y = cal.component(.year, from: now)
        let fyEndYear = cal.component(.month, from: now) >= 4 ? y + 1 : y   // FY Apr–Mar
        return "31 Jul \(fyEndYear)"
    }
    var financialYearLabel: String {
        let cal = Calendar.current, now = Date()
        let y = cal.component(.year, from: now) % 100
        let start = cal.component(.month, from: now) >= 4 ? y : y - 1
        return "FY \(start)–\(start + 1)"
    }

    // MARK: gamification — all derived from real data
    var xp: Int {
        goals.filter { $0.status == .achieved }.count * 300
        + milestones.filter(\.reached).count * 250
        + min(txns.count, 300) * 5
    }
    var level: Int { max(1, xp / 1000 + 1) }
    var nextLevelXP: Int { level * 1000 }
    var levelName: String {
        ["Saver", "Saver", "Builder", "Investor", "Strategist", "Master"][min(level, 5)]
    }
    /// Consecutive most-recent months that stayed within plan.
    var streakMonths: Int {
        var s = 0
        for m in planMonths.reversed() { if m.pct > 0 && m.pct <= 100 { s += 1 } else { break } }
        return s
    }

    // MARK: plan history — computed from real transactions
    private func monthSpend(monthsAgo i: Int) -> Double {
        let cal = Calendar.current
        guard let d = cal.date(byAdding: .month, value: -i, to: Date()) else { return 0 }
        return max(0, txns.filter { cal.isDate($0.date, equalTo: d, toGranularity: .month) && !investmentCategoryNames.contains($0.category) }
            .map(spendContribution).reduce(0, +))
    }

    /// Net spend a transaction contributes: debits add, refunds subtract, transfers/income ignored.
    func spendContribution(_ t: Txn) -> Double {
        if t.transfer { return 0 }
        if t.amount < 0 { return abs(t.amount) }
        if t.isRefund { return -abs(t.amount) }   // refund credit nets against spend
        return 0
    }
    /// Category names currently tagged Investment — excluded from cross-category "total spend"
    /// figures (a category's own cap/spend stays correct regardless; see `spend(inCategory:)`).
    private var investmentCategoryNames: Set<String> { Set(categories.filter { $0.kind == .investments }.map(\.name)) }
    // MARK: insights aggregations (exclude transfers; debit-only grouping)
    private func txnsInLast(months: Int) -> [Txn] {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        guard let from = cal.date(byAdding: .month, value: -(max(1, months) - 1), to: start) else { return txns }
        return txns.filter { $0.date >= from }
    }
    /// Net spend grouped by tag (a txn counts toward each of its tags). Sorted desc.
    func spendByTag(months: Int) -> [(tag: String, amount: Double)] {
        var m: [String: Double] = [:]
        for t in txnsInLast(months: months) {
            let c = spendContribution(t); guard c > 0 else { continue }
            if t.tags.isEmpty { m["Untagged", default: 0] += c }
            else { for tag in t.tags { m[tag, default: 0] += c } }
        }
        return m.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
    /// Net spend grouped by canonical brand (BrandCatalog, fallback merchant). Sorted desc.
    func spendByBrand(months: Int) -> [(brand: String, amount: Double)] {
        var m: [String: Double] = [:]
        for t in txnsInLast(months: months) {
            let c = spendContribution(t); guard c > 0 else { continue }
            let brand = BrandCatalog.classify([t.merchant, t.counterparty ?? ""].joined(separator: " ")).brand ?? t.merchant
            m[brand, default: 0] += c
        }
        return m.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
    /// International spend (INR) over the last N months, with a per-original-currency breakdown.
    func internationalSpend(months: Int) -> (total: Double, count: Int, byCurrency: [(currency: String, amount: Double)]) {
        let xs = txnsInLast(months: months).filter { $0.isInternational && !$0.transfer && $0.amount < 0 }
        let total = xs.reduce(0) { $0 + abs($1.amount) }
        var m: [String: Double] = [:]
        for t in xs {
            let c = (t.forexCurrency?.isEmpty == false) ? t.forexCurrency! : "Other"
            m[c, default: 0] += abs(t.amount)
        }
        return (total, xs.count, m.sorted { $0.value > $1.value }.map { (currency: $0.key, amount: $0.value) })
    }
    /// Loyalty rewards earned over the last N months, grouped by reward unit (points/miles/coins/cashback).
    func rewardsEarned(months: Int) -> [(currency: String, total: Double)] {
        var m: [String: Double] = [:]
        for t in txnsInLast(months: months) where (t.reward ?? 0) != 0 {
            m[t.rewardCurrency ?? "Reward", default: 0] += (t.reward ?? 0)
        }
        return m.sorted { $0.value > $1.value }.map { (currency: $0.key, total: $0.value) }
    }
    func monthlyTagSpend(_ tag: String, months: Int) -> [Double] {
        let cal = Calendar.current
        return (0..<max(1, months)).reversed().map { i in
            guard let d = cal.date(byAdding: .month, value: -i, to: Date()) else { return 0 }
            return txns.filter { $0.tags.contains(tag) && cal.isDate($0.date, equalTo: d, toGranularity: .month) }
                .map(spendContribution).reduce(0, +)
        }
    }

    /// Single source of truth for category spend, applying transfer/refund rules. Each category's
    /// `spent` is the net spend within *its own* current cap cycle (monthly by default, but a
    /// quarterly/annual/custom cap counts spend over that whole window — e.g. a yearly insurance cap).
    func recomputeSpent() {
        recomputeBankBalances()   // any change to txns can move an anchored account's live balance
        applyLoanLinks()          // EMI debits → "EMI & Loans" + "EMI" tag + linked loan (before totals)
        snapshotCaps()            // keep this month's cap snapshot current as caps are edited
        for i in categories.indices {
            let (start, end) = cycleWindow(for: categories[i])
            let name = categories[i].name
            let total = txns.filter { $0.category == name && $0.date >= start && $0.date < end }
                .map(spendContribution).reduce(0, +)
            categories[i].spent = max(0, total)
        }
        recomputeGoalProgress()   // bank-balance / txn changes can move asset-backed goal progress
    }

    /// First day of the financial year (Apr–Mar, India) containing `d`. Default cap-cycle anchor.
    static func financialYearStart(_ d: Date = Date()) -> Date {
        let cal = Calendar.current
        let y = cal.component(.year, from: d)
        let startYear = cal.component(.month, from: d) >= 4 ? y : y - 1
        return cal.date(from: DateComponents(year: startYear, month: 4, day: 1)) ?? d
    }

    /// The [start, end) of the cap cycle that currently contains today, for category `c`. Monthly and
    /// quarterly align to the calendar; annual/custom step from the category anchor (else the FY start).
    func cycleWindow(for c: BudgetCategory) -> (Date, Date) {
        let cal = Calendar.current, now = Date()
        switch c.period {
        case .monthly:
            let start = cal.dateInterval(of: .month, for: now)?.start ?? now
            return (start, cal.date(byAdding: .month, value: 1, to: start) ?? now)
        case .quarterly:
            let m = cal.component(.month, from: now)
            let qStartMonth = ((m - 1) / 3) * 3 + 1
            let start = cal.date(from: DateComponents(year: cal.component(.year, from: now), month: qStartMonth, day: 1)) ?? now
            return (start, cal.date(byAdding: .month, value: 3, to: start) ?? now)
        case .annual, .custom:
            let len = c.periodMonths
            let anchor = c.anchor ?? Self.financialYearStart(now)
            let monthsSince = cal.dateComponents([.month], from: anchor, to: now).month ?? 0
            let k = max(0, monthsSince / len)
            let start = cal.date(byAdding: .month, value: k * len, to: anchor) ?? anchor
            return (start, cal.date(byAdding: .month, value: len, to: start) ?? now)
        }
    }
    /// Locale/timezone-stable "YYYY-MM" key. Built from Calendar ints, never a DateFormatter,
    /// so the key can't shift with the device locale or calendar.
    static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Plan total for one month, from each category's snapshot of the cap in force then.
    /// Excludes Investment-kind categories, matching `planTotal`.
    func capTotal(forMonth key: String) -> Double {
        categories.filter { $0.kind != .investments }.map { $0.plan(forMonth: key) }.reduce(0, +)
    }

    /// Records the current month's caps. Called from `recomputeSpent()`, which runs on every mutation
    /// path, so a month's stored value settles at the cap in force at that month's last moment — the
    /// correct semantic. Keeps ~36 months; "YYYY-MM" sorts lexicographically, so pruning is a compare.
    func snapshotCaps() {
        let key = Self.monthKey(Date())
        let cutoff = Self.monthKey(Calendar.current.date(byAdding: .month, value: -36, to: Date()) ?? Date())
        for i in categories.indices {
            categories[i].capHistory[key] = categories[i].monthlyPlan
            if categories[i].capHistory.contains(where: { $0.key < cutoff }) {
                categories[i].capHistory = categories[i].capHistory.filter { $0.key >= cutoff }
            }
        }
    }

    var planMonths: [PlanMonth] {
        let cal = Calendar.current
        return (0...5).reversed().compactMap { i -> PlanMonth? in
            guard let d = cal.date(byAdding: .month, value: -i, to: Date()) else { return nil }
            let spend = monthSpend(monthsAgo: i)
            // Past months are judged against the cap that applied then; the current month stays live
            // so an in-month cap edit shows immediately.
            let total = i == 0 ? planTotal : capTotal(forMonth: Self.monthKey(d))
            let pct = total > 0 ? Int((spend/total*100).rounded()) : 0
            return PlanMonth(month: d.formatted(.dateTime.month(.abbreviated)), pct: pct, over: pct > 100)
        }
    }
    // MARK: - Search
    /// Every optional; an all-nil filter matches everything. Kept a plain struct so callers can
    /// compose drill-in presets with live chips without any shared state.
    struct TxnFilter {
        var account: String? = nil
        var category: String? = nil
        var tag: String? = nil
        var from: Date? = nil
        var to: Date? = nil
        var minAmount: Double? = nil
        var maxAmount: Double? = nil
        var internationalOnly = false
        var needsReviewOnly = false
        var hideTransfers = false
    }

    /// Lowercased, diacritic-folded haystack per txn, built once per `txns` change rather than per
    /// keystroke (thousands of rows × every character typed would otherwise refold the whole ledger).
    private var searchBlobs: [UUID: String] = [:]

    private func searchBlob(for t: Txn) -> String {
        if let b = searchBlobs[t.id] { return b }
        // Includes counterparty: UPI payees live there and usually differ from the cleaned merchant.
        let b = [t.merchant, t.counterparty ?? "", t.category, t.account, t.tags.joined(separator: " ")]
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        searchBlobs[t.id] = b
        return b
    }

    /// Split a raw query into normalised words. Multi-word queries AND together, and each word may
    /// match a different field.
    static func searchWords(_ q: String) -> [String] {
        q.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A numeric word also matches |amount| within ±0.5 — users type "649" for a −649 spend.
    func txnMatches(_ t: Txn, words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let hay = searchBlob(for: t)
        return words.allSatisfy { w in
            if hay.contains(w) { return true }
            if let n = Double(w) { return abs(abs(t.amount) - n) <= 0.5 }
            return false
        }
    }

    /// Pure search + filter over the whole ledger. Transfers stay visible unless explicitly hidden —
    /// finding a card bill payment is a legitimate search.
    func searchTxns(_ query: String, filter: TxnFilter = TxnFilter()) -> [Txn] {
        var xs = txns
        if let a = filter.account { xs = xs.filter { $0.account == a } }
        if let c = filter.category { xs = xs.filter { $0.category == c } }
        if let tg = filter.tag { xs = xs.filter { $0.tags.contains(tg) } }
        if let f = filter.from { xs = xs.filter { $0.date >= f } }
        if let t = filter.to { xs = xs.filter { $0.date <= t } }
        if let lo = filter.minAmount { xs = xs.filter { abs($0.amount) >= lo } }
        if let hi = filter.maxAmount { xs = xs.filter { abs($0.amount) <= hi } }
        if filter.internationalOnly { xs = xs.filter(\.isInternational) }
        if filter.needsReviewOnly { xs = xs.filter(\.needsReview) }
        if filter.hideTransfers { xs = xs.filter { !$0.transfer } }
        let words = Self.searchWords(query)
        guard !words.isEmpty else { return xs }
        return xs.filter { txnMatches($0, words: words) }
    }

    // MARK: - Cash-flow forecast
    /// Assembles live state into `CashflowForecast.Inputs`. All the judgement lives here; the maths
    /// lives in the pure `CashflowForecast`.
    func forecastInputs(today: Date = Date(), horizon: Int = 30) -> CashflowForecast.Inputs {
        let cal = Calendar.current
        let start = cal.startOfDay(for: today)
        let end = cal.date(byAdding: .day, value: horizon, to: start) ?? start
        var i = CashflowForecast.Inputs()
        // Liquid only — deposits and investments aren't spendable this month.
        i.startingBalance = banks.map(\.balance).reduce(0, +)

        // Income: project each monthly stream on its credit day. A stream already credited this month
        // (matching Income txn on/after its credit day) contributes nothing further; a stream whose day
        // has passed with no matching txn is still projected, flagged as late rather than dropped.
        let monthStart = cal.dateInterval(of: .month, for: start)?.start ?? start
        for s in incomeStreams {
            guard let day = s.creditDay, s.perPeriodAmount > 0 else { continue }
            let amount = s.monthly ? s.perPeriodAmount : s.perPeriodAmount / 12
            for m in 0...(horizon / 28 + 1) {
                guard let base = cal.date(byAdding: .month, value: m, to: monthStart),
                      let due = cal.date(bySetting: .day, value: min(day, cal.range(of: .day, in: .month, for: base)?.count ?? day), of: base)
                else { continue }
                guard due >= start, due <= end else { continue }
                let alreadyPaid = txns.contains {
                    $0.category == "Income" && $0.amount > 0
                        && cal.isDate($0.date, equalTo: due, toGranularity: .month)
                        && $0.date >= cal.date(byAdding: .day, value: -3, to: due)!
                }
                if alreadyPaid { continue }
                i.income.append(.init(label: s.name, date: due, amount: amount,
                                      expectedLate: due < start))
            }
        }

        // Cash outflows: predicted recurring charges (subscriptions AND transfers/SIPs — a SIP is a
        // real cash outflow even though it isn't spend) plus card bills falling due in the horizon.
        for g in upcomingCharges(within: horizon) {
            guard let d = g.nextDate else { continue }
            i.bills.append(.init(label: g.name, date: d, amount: -g.expectedAmount))
        }
        for c in cards {
            guard let due = c.dueDate, due >= start, due <= end else { continue }
            let amount = c.totalDue ?? c.outstanding
            guard amount > 0 else { continue }
            // A card bill is cash out, never budget spend — the purchases behind it were already
            // counted against categories when they happened.
            i.bills.append(.init(label: "\(c.name) bill", date: due, amount: -amount))
        }

        i.remainingBudget = categories.filter { $0.kind != .investments }
            .map { max(0, $0.monthlyPlan - $0.spent) }.reduce(0, +)
        return i
    }

    var forecast: CashflowForecast { CashflowForecast.compute(forecastInputs(), today: Date()) }

    /// Net spend for one category within an arbitrary [from, to) window (for Plan period/month views).
    func spend(inCategory name: String, from: Date, to: Date) -> Double {
        max(0, txns.filter { $0.category == name && $0.date >= from && $0.date < to }
            .map(spendContribution).reduce(0, +))
    }
    /// Net spend across all categories within an arbitrary [from, to) window. Excludes Investment-kind
    /// categories, matching `planTotal`/`spentTotal`.
    func totalSpend(from: Date, to: Date) -> Double {
        max(0, txns.filter { $0.date >= from && $0.date < to && !investmentCategoryNames.contains($0.category) }
            .map(spendContribution).reduce(0, +))
    }
    /// Real income credited within [from, to) — read-only Plan-tab summary; income never becomes a
    /// BudgetCategory since it has no cap/spent semantics. Filters on the literal category "Income"
    /// (not the `income` boolean) so refund credits — netted into their original spend category by
    /// `classify()` — can't double-count as income.
    func totalIncome(from: Date, to: Date) -> Double {
        txns.filter { $0.category == "Income" && $0.date >= from && $0.date < to }.map(\.amount).reduce(0, +)
    }
    var currentMonthName: String { Date().formatted(.dateTime.month(.wide)) }
    var daysLeftInMonth: Int {
        let cal = Calendar.current, now = Date()
        let total = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        return max(0, total - cal.component(.day, from: now))
    }

    // MARK: goal actions
    func cycleGoalStatus(_ goal: Goal) {
        guard let i = goals.firstIndex(of: goal), goals[i].status != .achieved else { return }
        goals[i].status = goals[i].status.next; save()
    }
    func setGoalStatus(_ goal: Goal, _ status: GoalStatus) {
        guard let i = goals.firstIndex(of: goal) else { return }
        goals[i].status = status; save()
    }
    func reactivate(_ goal: Goal) { setGoalStatus(goal, .onTrack) }
    func pause(_ goal: Goal) { setGoalStatus(goal, .paused) }

    // MARK: manual ingestion
    func addGoal(_ g: Goal) { goals.insert(g, at: 0); save() }
    func addDeposit(_ d: Deposit) { deposits.append(d); recomputeGoalProgress(); save() }
    func addBank(_ b: BankAccount) { banks.append(b); recomputeBankBalances(); save() }
    func addCard(_ c: CreditCard) { cards.append(c); save() }
    func addCategory(_ c: BudgetCategory) { categories.append(c); save() }
    func addIncomeStream(_ s: IncomeStream) { incomeStreams.append(s); save() }
    func addInvestment(_ i: Investment) { investments.append(i); recomputeGoalProgress(); save() }

    func remove(category: BudgetCategory) {
        guard !category.isSystem else { return }   // base categories are maintained, not deletable
        categories.removeAll { $0.id == category.id }; save()
    }
    func remove(bank: BankAccount) {
        banks.removeAll { $0.id == bank.id }
        purgeAccountData(name: bank.name, mask: bank.mask)
        recomputeSpent(); save()
    }
    func remove(card: CreditCard) {
        cards.removeAll { $0.id == card.id }
        purgeAccountData(name: card.name, mask: card.mask)
        recomputeSpent(); save()
    }
    /// Removes an account/card's transactions, its statement records, and any conflicts tied to them.
    private func purgeAccountData(name: String, mask: String) {
        let stmtIds = Set(statements.filter { $0.accountName == name || $0.accountMask == mask }.map(\.id))
        statements.removeAll { stmtIds.contains($0.id) }
        txns.removeAll { $0.account == name || ($0.statementRecordId.map { stmtIds.contains($0) } ?? false) }
        conflicts.removeAll { c in
            (c.txnId.map { id in !txns.contains { $0.id == id } } ?? false)   // its txn is gone
                || (c.statementRecordId.map { stmtIds.contains($0) } ?? false)
        }
    }
    /// Delete a statement record together with every transaction it ingested (and its conflicts).
    func remove(statement: StatementRecord) {
        txns.removeAll { $0.statementRecordId == statement.id }
        conflicts.removeAll { $0.statementRecordId == statement.id }
        statements.removeAll { $0.id == statement.id }
        recomputeSpent(); save()   // recomputeSpent also refreshes asset-backed goal progress
    }
    func remove(deposit: Deposit) { deposits.removeAll { $0.id == deposit.id }; recomputeGoalProgress(); save() }
    func remove(goal: Goal) { goals.removeAll { $0.id == goal.id }; save() }
    func remove(stream: IncomeStream) { incomeStreams.removeAll { $0.id == stream.id }; save() }
    func remove(investment: Investment) { investments.removeAll { $0.id == investment.id }; recomputeGoalProgress(); save() }

    // MARK: edit (update in place by id)
    func update(_ b: BankAccount) {
        guard let i = banks.firstIndex(where: { $0.id == b.id }) else { return }
        let oldName = banks[i].name
        banks[i] = b
        if oldName != b.name { for j in txns.indices where txns[j].account == oldName { txns[j].account = b.name } }
        recomputeBankBalances()   // re-derive in case the manual edit re-anchored the balance
        recomputeGoalProgress()
        save()
    }
    func update(_ c: CreditCard) {
        guard let i = cards.firstIndex(where: { $0.id == c.id }) else { return }
        let oldName = cards[i].name
        cards[i] = c
        if oldName != c.name { renameAccountTxns(from: oldName, to: c.name) }
        save()
    }
    func update(_ d: Deposit) { if let i = deposits.firstIndex(where: { $0.id == d.id }) { deposits[i] = d; recomputeGoalProgress(); save() } }
    func update(_ g: Goal) { if let i = goals.firstIndex(where: { $0.id == g.id }) { goals[i] = g; save() } }
    func update(_ s: IncomeStream) { if let i = incomeStreams.firstIndex(where: { $0.id == s.id }) { incomeStreams[i] = s; save() } }
    func update(_ inv: Investment) { if let i = investments.firstIndex(where: { $0.id == inv.id }) { investments[i] = inv; recomputeGoalProgress(); save() } }
    func update(_ c: BudgetCategory) {
        guard let i = categories.firstIndex(where: { $0.id == c.id }) else { return }
        var c = c
        let oldName = categories[i].name
        if categories[i].isSystem { c.name = oldName; c.isSystem = true }   // base names are locked
        categories[i] = c
        if oldName != c.name { for j in txns.indices where txns[j].category == oldName { txns[j].category = c.name } }
        save()
    }
    /// Edit a transaction: reverse its old balance effect, apply the new, recompute spend.
    func update(_ t: Txn) {
        guard let i = txns.firstIndex(where: { $0.id == t.id }) else { return }
        let old = txns[i]
        if let bi = banks.firstIndex(where: { $0.name == old.account }) { banks[bi].balance -= old.amount }
        txns[i] = t
        if let bi = banks.firstIndex(where: { $0.name == t.account }) { banks[bi].balance += t.amount }
        // Editing a flagged transaction is how the user fixes it — clear its review flag + conflicts.
        if old.needsReview { resolveConflicts(forTxn: t.id) }
        recomputeSpent()
        save()
        // If the user recategorised, remember it for this merchant/counterparty.
        if old.category != t.category, !t.income {
            let key = t.counterparty ?? t.merchant
            if !key.isEmpty { learnMerchant(key, category: t.category) }
        }
    }

    // MARK: goal ↔ asset allocation
    /// Live value a single allocation contributes to its goal (asset value × percent, or cash amount).
    func allocationValue(_ a: GoalAllocation) -> Double {
        switch a.kind {
        case .cash: return a.amount
        case .deposit: return (deposits.first { $0.id == a.assetId }?.current ?? 0) * a.percent / 100
        case .investment: return (investments.first { $0.id == a.assetId }?.currentValue ?? 0) * a.percent / 100
        case .bank: return (banks.first { $0.id == a.assetId }?.balance ?? 0) * a.percent / 100
        }
    }
    /// Total live value backing a goal from its linked assets.
    func allocatedValue(_ g: Goal) -> Double { g.allocations.reduce(0) { $0 + allocationValue($1) } }
    /// A goal's effective saved amount: derived from assets when any are linked, else the manual figure.
    func savedFor(_ g: Goal) -> Double { g.allocations.isEmpty ? g.saved : allocatedValue(g) }
    func progress(_ g: Goal) -> Double { g.target > 0 ? min(1, savedFor(g) / g.target) : 0 }
    /// Display name for an allocation's underlying asset.
    func assetName(_ a: GoalAllocation) -> String {
        switch a.kind {
        case .cash: return a.note.isEmpty ? "Cash" : a.note
        case .deposit: return deposits.first { $0.id == a.assetId }.map { "\($0.bank) \($0.tag)" } ?? "Deposit (removed)"
        case .investment: return investments.first { $0.id == a.assetId }?.name ?? "Investment (removed)"
        case .bank: return banks.first { $0.id == a.assetId }?.name ?? "Account (removed)"
        }
    }
    /// How much of one asset is already committed across all goals (advisory; >100% is allowed but warned).
    func allocatedPercent(kind: AllocationKind, assetId: UUID) -> Double {
        goals.flatMap(\.allocations).filter { $0.kind == kind && $0.assetId == assetId }.reduce(0) { $0 + $1.percent }
    }
    /// Recompute the derived `saved`/`status` for every asset-backed goal so existing reads
    /// (widgets, snapshot, level/XP, GoalsView) stay correct without touching their call sites.
    func recomputeGoalProgress() {
        for i in goals.indices where !goals[i].allocations.isEmpty {
            // cache each allocation's current contribution (for display when an asset later disappears)
            for j in goals[i].allocations.indices where goals[i].allocations[j].kind != .cash {
                goals[i].allocations[j].amount = allocationValue(goals[i].allocations[j])
            }
            let derived = goals[i].allocations.reduce(0.0) { $0 + allocationValue($1) }
            goals[i].saved = derived
            if goals[i].status != .paused {
                goals[i].status = (derived >= goals[i].target && goals[i].target > 0) ? .achieved
                    : (goals[i].status == .achieved ? .onTrack : goals[i].status)
            }
        }
    }
    func addAllocation(_ a: GoalAllocation, to goal: Goal) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[i].allocations.append(a); recomputeGoalProgress(); save()
    }
    func removeAllocation(_ id: UUID, from goal: Goal) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[i].allocations.removeAll { $0.id == id }; recomputeGoalProgress(); save()
    }
    func setAllocations(_ allocs: [GoalAllocation], for goal: Goal) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[i].allocations = allocs; recomputeGoalProgress(); save()
    }
    func updateAllocation(_ a: GoalAllocation, in goal: Goal) {
        guard let gi = goals.firstIndex(where: { $0.id == goal.id }),
              let ai = goals[gi].allocations.firstIndex(where: { $0.id == a.id }) else { return }
        goals[gi].allocations[ai] = a; recomputeGoalProgress(); save()
    }

    // MARK: live quotes (stocks via optional API, mutual funds via AMFI NAV)
    @MainActor
    func refreshQuotes() async {
        let updated = await QuoteProvider.shared.refresh(investments)
        guard !updated.isEmpty else { return }
        for inv in updated { if let i = investments.firstIndex(where: { $0.id == inv.id }) { investments[i] = inv } }
        recomputeGoalProgress()
        save()
    }

    @MainActor
    func refreshFX() async {
        let codes = Array(Set(incomeStreams.map(\.currency)))
        guard codes.contains(where: { $0 != "INR" }) else { return }
        let r = await FXProvider.shared.ratesToINR(codes)
        guard !r.isEmpty else { return }
        for (k, v) in r { fxRates[k] = v }
        save()
    }
    func remove(txn: Txn) {
        txns.removeAll { $0.id == txn.id }
        conflicts.removeAll { $0.txnId == txn.id }
        recomputeSpent(); save()
    }

    // MARK: conflicts (ingestion needs-review queue)
    var unresolvedConflicts: [DataConflict] { conflicts.filter { !$0.resolved } }
    /// Mark every conflict on a transaction resolved and clear its "needs review" marker.
    func resolveConflicts(forTxn id: UUID) {
        for j in conflicts.indices where conflicts[j].txnId == id { conflicts[j].resolved = true }
        if let i = txns.firstIndex(where: { $0.id == id }) {
            txns[i].needsReview = false
            txns[i].tags.removeAll { $0 == "Needs review" }
        }
        save()
    }
    /// Dismiss a single conflict; if it was the txn's last open one, clear the review marker too.
    func resolve(conflict: DataConflict) {
        if let i = conflicts.firstIndex(where: { $0.id == conflict.id }) { conflicts[i].resolved = true }
        if let tid = conflict.txnId, !conflicts.contains(where: { $0.txnId == tid && !$0.resolved }),
           let ti = txns.firstIndex(where: { $0.id == tid }) {
            txns[ti].needsReview = false; txns[ti].tags.removeAll { $0 == "Needs review" }
        }
        save()
    }
    func clearResolvedConflicts() { conflicts.removeAll { $0.resolved }; save() }
    /// The transaction a conflict refers to (for opening the editor).
    func txn(for conflict: DataConflict) -> Txn? { conflict.txnId.flatMap { id in txns.first { $0.id == id } } }
    func statement(for conflict: DataConflict) -> StatementRecord? {
        conflict.statementRecordId.flatMap { id in statements.first { $0.id == id } }
    }

    func logTxn(_ t: Txn) {
        var t = t
        let cls = classify(merchant: t.merchant, counterparty: t.counterparty, narration: t.merchant, income: t.income)
        if t.tags.isEmpty { t.tags = cls.tags }
        if !t.transfer { t.transfer = cls.transfer }
        txns.insert(t, at: 0)
        if let bi = banks.firstIndex(where: { $0.name == t.account }) { banks[bi].balance += t.amount }
        recomputeSpent()
        save()
    }

    // MARK: widgets + live activity
    var topGoal: Goal? { goals.first { $0.active } ?? goals.first }
    func publishSnapshot() {
        let g = topGoal
        WTMSnapshot(netWorth: liquidNetWorth, netWorthChange: nwChange, spent: spentTotal, plan: planTotal,
                    targetPct: toTargetPct, topGoalTitle: g?.title ?? "No goal yet",
                    topGoalSaved: g?.saved ?? 0, topGoalTarget: g?.target ?? 1,
                    streakMonths: streakMonths, nwHistory: nwHistory, updated: Date(),
                    cats: intentCategorySnaps, quickPresets: intentQuickPresets).save()
        WidgetCenter.shared.reloadAllTimelines()
        if BudgetLiveActivity.isRunning {
            BudgetLiveActivity.update(spent: spentTotal, plan: planTotal, daysLeft: daysLeftInMonth)
        }
    }

    // MARK: bank-sync / statement merge
    /// `adjustBalances` true only for live feeds (Gmail) where each new txn moves the
    /// running balance; statement/CSV/AA imports are historical and must not.
    @discardableResult
    func mergeSynced(accounts: [SyncedAccount], txns incoming: [SyncedTxn], adjustBalances: Bool = false,
                     reconcile: Bool = false, statementRecordId: UUID? = nil) -> Int {
        for a in accounts { upsertAccount(a) }
        let known = Set(self.txns.compactMap(\.externalId))
        var added = 0
        for s in incoming.sorted(by: { $0.date < $1.date }) where !known.contains(s.externalId) {
            // auto-create the source bank/card by last-4 if unseen
            if s.source == .card { ensureCard(mask: s.accountMask, bankCode: s.bankCode) }
            else if s.source == .bank { ensureBank(mask: s.accountMask, bankCode: s.bankCode) }

            // Unattributable rows (an issuer we hold no account for) are dropped rather than parked
            // on an arbitrary account — see `accountName`.
            guard let accName = accountName(forMask: s.accountMask, source: s.source, bankCode: s.bankCode) else { continue }
            // Statement imports reconcile against existing alert transactions by amount+date so the
            // same event isn't stored twice with two different merchant spellings.
            if reconcile, let i = duplicateBankIndex(for: s, accountName: accName) {
                if txns[i].statementId == nil { enrichBank(&txns[i], with: s) }
                continue   // already have this transaction — don't add, don't move the balance
            }
            let merchant = s.merchant ?? Self.prettyMerchant(s.narration)
            let cl = classify(merchant: merchant, counterparty: s.counterparty, narration: s.narration, income: s.amount > 0)
            var tags = cl.tags
            if s.hasConflict { tags.append("Needs review") }
            let t = Txn(merchant: merchant, symbol: cl.symbol, category: cl.category, account: accName,
                        amount: s.amount, date: s.date, externalId: s.externalId,
                        source: s.source, counterparty: s.counterparty,
                        statementRecordId: statementRecordId, needsReview: s.hasConflict, tags: tags, transfer: cl.transfer)
            txns.insert(t, at: 0)
            registerConflicts(for: s, txnId: t.id, recordId: statementRecordId)
            if adjustBalances {
                // Anchored accounts re-derive from (anchor + later txns) in recomputeBankBalances()
                // below — adding here too would double-count. Only un-anchored accounts run a balance.
                // Keyed on the *resolved* account, not the raw mask: a debit-card alert carries the
                // card's last-4, so matching on the mask skipped the balance move for every one of
                // them and left the ledger and the balance disagreeing by the debit-card total.
                if s.source == .bank, let bi = banks.firstIndex(where: { $0.name == accName }) {
                    if banks[bi].balanceAnchor == nil { banks[bi].balance += s.amount }
                } else if s.source == .card, let ci = cards.firstIndex(where: { $0.name == accName }) {
                    cards[ci].outstanding = max(0, cards[ci].outstanding - s.amount)
                }
            }
            added += 1
        }
        correlateTransfers()
        recomputeSpent()
        save()
        return added
    }

    /// Import a parsed statement: set the account's exact figures (outstanding/limit/product/
    /// rewards) and reconcile each statement transaction against existing alert transactions —
    /// enriching a match in place (category/merchant/source) instead of creating a duplicate.
    @discardableResult
    func mergeStatement(account: SyncedAccount, txns incoming: [SyncedTxn],
                        statementRecordId: UUID? = nil) -> (added: Int, enriched: Int) {
        upsertAccount(account)
        // `upsertAccount` has just created/updated this account, so resolution always succeeds.
        guard let accName = accountName(forMask: account.mask, source: account.kind, bankCode: account.bankCode) else {
            return (0, 0)
        }
        let knownExt = Set(self.txns.compactMap(\.externalId))
        var added = 0, enriched = 0
        for s in incoming.sorted(by: { $0.date < $1.date }) {
            if knownExt.contains(s.externalId) { continue }                 // this exact statement row already imported
            if let i = reconcileIndex(for: s, accountName: accName) {
                enrich(&txns[i], with: s); enriched += 1
            } else {
                let merchant = s.merchant ?? Self.prettyMerchant(s.narration)
                let cl = classify(merchant: merchant, counterparty: s.counterparty, narration: s.narration, income: s.amount > 0)
                let cat = (s.category?.isEmpty == false) ? s.category! : cl.category
                let sym = categories.first { $0.name == cat }?.symbol ?? cl.symbol
                var tags = cl.tags
                if s.hasConflict { tags.append("Needs review") }
                if s.cardholder != nil { tags.append("Add-on") }   // spend on an add-on card
                if s.isInternational { tags.append("International") }
                let t = Txn(merchant: merchant, symbol: sym, category: cat, account: accName,
                            amount: s.amount, date: s.date, externalId: s.externalId,
                            source: s.source, counterparty: s.counterparty, statementId: s.externalId,
                            statementRecordId: statementRecordId, needsReview: s.hasConflict, tags: tags, transfer: cl.transfer,
                            cardholder: s.cardholder, reward: s.reward, rewardCurrency: s.rewardCurrency,
                            forexCurrency: s.forexCurrency, forexAmount: s.forexAmount)
                txns.insert(t, at: 0)
                registerConflicts(for: s, txnId: t.id, recordId: statementRecordId)
                added += 1
            }
        }
        correlateTransfers()
        recomputeSpent()
        save()
        return (added, enriched)
    }

    /// Finds the closest unreconciled alert transaction matching this statement row.
    private func reconcileIndex(for s: SyncedTxn, accountName: String) -> Int? {
        let target = abs(s.amount), inc = s.amount > 0
        var best: Int? = nil, bestDelta = Double.greatestFiniteMagnitude
        for (i, t) in txns.enumerated() where t.statementId == nil && t.account == accountName && t.income == inc {
            guard abs(abs(t.amount) - target) < 0.01 else { continue }
            let delta = abs(t.date.timeIntervalSince(s.date))
            if delta <= 3 * 86400, delta < bestDelta { best = i; bestDelta = delta }
        }
        return best
    }
    /// Enriches an existing transaction with the statement's better data (category, merchant, tags).
    private func enrich(_ t: inout Txn, with s: SyncedTxn) {
        if let c = s.category, !c.isEmpty {
            t.category = c
            t.symbol = categories.first { $0.name == c }?.symbol ?? Self.symbolFor(c)
        }
        if let m = s.merchant, !m.isEmpty { t.merchant = m }
        let cl = classify(merchant: t.merchant, counterparty: t.counterparty, narration: s.narration, income: t.amount > 0)
        t.tags = Self.uniq(t.tags + cl.tags)
        if let h = s.cardholder { t.cardholder = h; t.tags = Self.uniq(t.tags + ["Add-on"]) }
        if let r = s.reward { t.reward = r; t.rewardCurrency = s.rewardCurrency }
        if let fc = s.forexCurrency { t.forexCurrency = fc; t.forexAmount = s.forexAmount }
        if s.isInternational { t.tags = Self.uniq(t.tags + ["International"]) }
        if cl.transfer { t.transfer = true }
        t.source = .card
        t.statementId = s.externalId
        // spend is recomputed by the caller after the merge loop
    }
    private func renameAccountTxns(from old: String, to new: String) {
        for i in txns.indices where txns[i].account == old { txns[i].account = new }
    }

    /// Reconstruct a live bank balance from a statement's stated closing: add every transaction for
    /// this account dated strictly after the statement's as-of date. This is why a May-31 statement
    /// no longer pins the balance to May when June alerts already arrived. Called *before* the
    /// statement's own (≤ asOf) transactions are inserted, so they're never double-counted.
    private func liveBalance(statedBalance: Double, asOf: Date?, accountName: String) -> Double {
        guard let asOf else { return statedBalance }
        let later = txns.filter { $0.account == accountName && $0.date > asOf }.map(\.amount).reduce(0, +)
        return statedBalance + later
    }

    // MARK: - Balance anchors (iron-clad reconstruction)
    // The displayed `balance` of an anchored account is always *derived*: the last authoritative
    // reading (`balanceAnchor` as of `balanceAsOf`) plus every transaction dated after it. This makes
    // the figure self-healing (a missed/duplicate txn can't permanently corrupt a running total) and
    // order-independent (the newest reading always wins).

    /// Reconstruct an anchored account's live balance; un-anchored accounts keep their stored balance.
    private func derivedBalance(_ b: BankAccount) -> Double {
        guard let anchor = b.balanceAnchor, let asOf = b.balanceAsOf else { return b.balance }
        return liveBalance(statedBalance: anchor, asOf: asOf, accountName: b.name)
    }
    /// Adopt an authoritative balance reading for an account. Only advances the anchor *forward* in
    /// time, so a stale statement/email can never clobber a newer reading; then re-derives the balance.
    private func setBalanceAnchor(mask: String, balance: Double, asOf: Date) {
        guard let i = banks.firstIndex(where: { $0.mask == mask }) else { return }
        if let prev = banks[i].balanceAsOf, asOf < prev { return }   // keep the newer reading
        banks[i].balanceAnchor = balance
        banks[i].balanceAsOf = asOf
        banks[i].balance = derivedBalance(banks[i])
    }
    /// Re-derive every anchored account's displayed balance. Idempotent — safe to call after any
    /// change to `txns`, which is what makes the balance self-healing.
    func recomputeBankBalances() {
        for i in banks.indices where banks[i].balanceAnchor != nil {
            banks[i].balance = derivedBalance(banks[i])
        }
    }

    /// Finds an existing transaction that is the same real-world event as `s` regardless of merchant
    /// text (alert vs statement spell the payee differently): same account, same sign, equal amount,
    /// within a few days. Used to stop bank statements from duplicating Gmail alert transactions.
    private func duplicateBankIndex(for s: SyncedTxn, accountName: String) -> Int? {
        let target = abs(s.amount), inc = s.amount > 0
        var best: Int? = nil, bestDelta = Double.greatestFiniteMagnitude
        for (i, t) in txns.enumerated() where t.account == accountName && t.income == inc {
            guard t.externalId != s.externalId, abs(abs(t.amount) - target) < 0.01 else { continue }
            let delta = abs(t.date.timeIntervalSince(s.date))
            if delta <= 4 * 86400, delta < bestDelta { best = i; bestDelta = delta }
        }
        return best
    }
    /// Enrich a prior alert transaction with a bank statement's better data (cleaner merchant,
    /// category, tags) and mark it statement-confirmed. Unlike `enrich`, never forces `.card`.
    private func enrichBank(_ t: inout Txn, with s: SyncedTxn) {
        if let m = s.merchant, !m.isEmpty, m.count > t.merchant.count { t.merchant = m }
        if let c = s.category, !c.isEmpty {
            t.category = c
            t.symbol = categories.first { $0.name == c }?.symbol ?? Self.symbolFor(c)
        }
        if (t.counterparty ?? "").isEmpty, let cp = s.counterparty { t.counterparty = cp }
        let cl = classify(merchant: t.merchant, counterparty: t.counterparty, narration: s.narration, income: t.amount > 0)
        t.tags = Self.uniq(t.tags + cl.tags)
        if cl.transfer { t.transfer = true }
        if t.statementId == nil { t.statementId = s.externalId }
    }

    /// Unique, ordered bank + card display names for pickers.
    var accountNames: [String] {
        var seen = Set<String>()
        return (banks.map(\.name) + cards.map(\.name)).filter { seen.insert($0).inserted }
    }
    /// Legacy migration: make any colliding bank/card names unique by appending ••mask.
    private func dedupeAccountNames() {
        var seen = Set<String>()
        for i in banks.indices {
            if !seen.insert(banks[i].name).inserted, !banks[i].name.contains("••") {
                banks[i].name = "\(banks[i].name) ••\(banks[i].mask)"; seen.insert(banks[i].name)
            }
        }
        for i in cards.indices {
            if !seen.insert(cards[i].name).inserted, !cards[i].name.contains("••") {
                cards[i].name = "\(cards[i].name) ••\(cards[i].mask)"; seen.insert(cards[i].name)
            }
        }
    }

    /// Links a bank-side credit-card bill payment (debit) to the matching card-side payment
    /// credit, flagging both as transfers so neither is counted as spend or income.
    func correlateTransfers() {
        let cardCredits = txns.filter { $0.source == .card && $0.amount > 0 && ($0.transfer || Classifier.isCardPaymentCredit($0.merchant)) }
        for c in cardCredits {
            if let bi = txns.firstIndex(where: { $0.source == .bank && $0.amount < 0 && !$0.transfer
                && abs(abs($0.amount) - abs(c.amount)) < 0.01 && abs($0.date.timeIntervalSince(c.date)) <= 5 * 86400 }) {
                txns[bi].transfer = true
                if !txns[bi].tags.contains("Credit card bill") { txns[bi].tags.append("Credit card bill") }
            }
        }
        correlateOwnAccountTransfers()
        reconcileCardDues()
    }

    /// Moving money between the user's *own* accounts is not spend and not income — but it arrives as
    /// two independent alerts (a debit on the source, a credit on the destination), so both totals
    /// inflate unless the pair is recognised. The alert names the far account
    /// ("IB FUNDS TRANSFER DR-XXXXXXXXXX2421-…", "…credited to the account ending xxxxxxxxxx2421"),
    /// which the parsers surface as a `••<last4>` suffix; a suffix matching an account we own is the
    /// signal. Only the *destination* is asserted by the mail, so the matching credit is still
    /// confirmed by amount and date before either side is flagged.
    private func correlateOwnAccountTransfers() {
        let ownMasks = Set(banks.map(\.mask)).filter { !$0.isEmpty }
        for i in txns.indices {
            let t = txns[i]
            guard t.source == .bank, t.amount < 0, !t.transfer,
                  let r = t.merchant.range(of: #"••(\d{3,})"#, options: .regularExpression) else { continue }
            let target = String(t.merchant[r].dropFirst(2))
            guard ownMasks.contains(target), banks.first(where: { $0.name == t.account })?.mask != target,
                  let dest = banks.first(where: { $0.mask == target }) else { continue }
            // The mirror credit on the destination account, same amount, within a few days.
            let mirror = txns.firstIndex { c in
                c.source == .bank && c.amount > 0 && c.account == dest.name
                    && abs(c.amount + t.amount) < 0.01 && abs(c.date.timeIntervalSince(t.date)) <= 3 * 86400
            }
            guard let mi = mirror else { continue }
            for j in [i, mi] {
                txns[j].transfer = true
                if !txns[j].tags.contains("Self transfer") { txns[j].tags.append("Self transfer") }
            }
        }
    }

    /// Flip a card's due to "cleared" once a bill payment ≥ its minimum lands after the statement —
    /// silences the reminder without waiting for the next statement. `dueClearedAt` makes this sticky
    /// so a payment made before the next import doesn't re-alert. Reuses the existing card-payment
    /// classification (correlateTransfers) rather than adding a second matcher.
    private func reconcileCardDues() {
        for i in cards.indices {
            guard let dueOn = cards[i].dueDate, cards[i].dueClearedAt == nil else { continue }
            let minDue = cards[i].minDue ?? 0
            // A payment is a card-side credit dated on/after the statement (≈ due date − 40d).
            let statementFloor = dueOn.addingTimeInterval(-40 * 86400)
            let payment = txns.first { t in
                t.source == .card && t.account == cards[i].name && t.amount > 0
                    && t.date >= statementFloor
                    && (t.transfer || Classifier.isCardPaymentCredit(t.merchant))
                    && t.amount + 0.01 >= minDue
            }
            if let payment {
                cards[i].dueClearedAt = payment.date
                NotificationManager.cancelCardDue(mask: cards[i].mask)
            }
        }
    }

    /// Import a parsed statement (single or combined): cards reconcile via mergeStatement, bank
    /// accounts via mergeSynced (balances + classified txns), plus FD/RD deposits.
    @discardableResult
    func mergeImport(_ r: ImportResult, record: StatementRecord? = nil) -> Int {
        var n = 0
        let rid = record?.id
        let cards = r.accounts.filter { $0.kind == .card }
        let banks = r.accounts.filter { $0.kind == .bank }
        for c in cards {
            let res = mergeStatement(account: c, txns: r.txns.filter { $0.accountMask == c.mask }, statementRecordId: rid)
            n += res.added + res.enriched
        }
        let bankTxns = r.txns.filter { t in !cards.contains { $0.mask == t.accountMask } }
        if !banks.isEmpty || !bankTxns.isEmpty { n += mergeSynced(accounts: banks, txns: bankTxns, reconcile: true, statementRecordId: rid) }
        let depAdded = mergeDeposits(r.deposits)
        // Finalise & record the statement so it shows in the ledger and its txns can be cascade-deleted.
        if var rec = record {
            rec.txnCount = txns.filter { $0.statementRecordId == rid }.count
            rec.depositCount = depAdded
            if rec.accountName == nil, let a = r.accounts.first {
                rec.accountName = accountName(forMask: a.mask, source: a.kind, bankCode: a.bankCode)
                rec.accountMask = a.mask
            }
            if rec.periodStart == nil {
                let dates = r.txns.map(\.date).sorted()
                rec.periodStart = dates.first; rec.periodEnd = dates.last
            }
            statements.insert(rec, at: 0)
        }
        save()
        return n
    }
    /// Upsert deposits by their account-number identifier (so monthly re-imports don't duplicate).
    /// Returns the number of brand-new deposits added.
    @discardableResult
    func mergeDeposits(_ ds: [Deposit]) -> Int {
        guard !ds.isEmpty else { return 0 }
        var added = 0
        for d in ds {
            if let id = d.identifier, let i = deposits.firstIndex(where: { $0.identifier == id }) {
                deposits[i].bank = d.bank; deposits[i].tag = d.tag; deposits[i].rate = d.rate
                deposits[i].current = d.current; deposits[i].startDate = d.startDate; deposits[i].maturityDate = d.maturityDate
            } else { deposits.append(d); added += 1 }
        }
        recomputeGoalProgress()
        save()
        return added
    }
    /// Builds DataConflict entries for any field a parser couldn't resolve on an imported row.
    private func registerConflicts(for s: SyncedTxn, txnId: UUID, recordId: UUID?) {
        guard s.hasConflict else { return }
        let ctx = s.rawContext.isEmpty ? s.narration : s.rawContext
        func add(_ field: String, _ reason: String) {
            conflicts.append(DataConflict(txnId: txnId, statementRecordId: recordId, field: field, reason: reason, context: ctx))
        }
        if !s.dateResolved { add("date", "Couldn't read the transaction date — a nearby date was used as a placeholder.") }
        if !s.amountResolved { add("amount", "Couldn't read the amount — set to ₹0 pending review.") }
        if !s.merchantResolved { add("merchant", "No merchant or description was found for this transaction.") }
    }

    /// Set exact balances from authoritative signals (e.g. HDFC "available balance" emails). Each
    /// reading is an anchor `(balance, asOf)`: we keep only the **newest** reading per account, so
    /// Gmail's fetch order or a rescan of older daily emails can never let a stale value win.
    func applyBalances(_ updates: [BalanceUpdate]) {
        guard !updates.isEmpty else { return }
        var latest: [String: BalanceUpdate] = [:]
        for u in updates where u.kind == .bank {
            if let cur = latest[u.mask], cur.asOf >= u.asOf { continue }
            latest[u.mask] = u
        }
        for u in latest.values { setBalanceAnchor(mask: u.mask, balance: u.balance, asOf: u.asOf) }
        recomputeGoalProgress()
        save()
    }

    // MARK: auto-map helpers (catalog-driven, no logos)
    private func upsertAccount(_ a: SyncedAccount) {
        if a.kind == .card {
            ensureCard(mask: a.mask, bankCode: a.bankCode, cardName: a.cardName)
            if let i = cards.firstIndex(where: { $0.mask == a.mask }) {
                if let l = a.limit, l > 0 { cards[i].limit = l }
                if a.balance > 0 { cards[i].outstanding = a.balance }   // statement total due = exact outstanding
                if cards[i].tier == nil, let t = a.tier { cards[i].tier = t }
                if cards[i].bankCode == nil { cards[i].bankCode = a.bankCode }
                // A statement is authoritative about the product — set/correct it even if the
                // card was previously created with a generic or wrongly-guessed name.
                if let prod = a.cardName, let info = CardCatalog.all.first(where: { $0.name == prod }) {
                    let old = cards[i].name
                    let newName = "\(info.name) ••\(cards[i].mask)"
                    cards[i].name = newName
                    cards[i].network = info.network
                    cards[i].tier = info.tier
                    cards[i].colorHex = info.gradient.first
                    if old != newName { renameAccountTxns(from: old, to: newName) }
                }
                if let rk = a.rewardKind { cards[i].rewardKind = rk }
                if let rb = a.rewardBalance { cards[i].rewardBalance = rb }
                // Card bill due: only advance to a *newer* statement's figures (forward-only, like the
                // balance anchor) so re-importing an older statement can't resurrect a stale due date.
                if let dueOn = a.dueDate, cards[i].dueDate == nil || dueOn > cards[i].dueDate! {
                    cards[i].dueDate = dueOn
                    cards[i].totalDue = a.totalDue ?? (a.balance > 0 ? a.balance : nil)
                    cards[i].minDue = a.minDue
                    cards[i].dueClearedAt = nil   // new statement cycle — re-arm the reminder
                    NotificationManager.scheduleCardDue(mask: cards[i].mask, cardName: cards[i].name,
                                                        dueDate: dueOn, totalDue: cards[i].totalDue)
                }
            }
            return
        }
        if let i = banks.firstIndex(where: { $0.mask == a.mask }) {
            // A statement's closing balance is stated *as of* its period end. Route it through the
            // anchor so it only wins if it's newer than the current reading, and the live balance is
            // reconstructed from any transactions dated after it (never clobbers a newer Gmail alert).
            if a.balance != 0 {
                if let asOf = a.asOf { setBalanceAnchor(mask: a.mask, balance: a.balance, asOf: asOf) }
                else { banks[i].balance = a.balance }   // no as-of date → take it verbatim (legacy)
            }
            if banks[i].bankCode == nil { banks[i].bankCode = a.bankCode }
            if banks[i].ifsc == nil { banks[i].ifsc = a.ifsc }
            if banks[i].branch == nil { banks[i].branch = a.branch }
            if banks[i].tier == nil { banks[i].tier = a.tier }
            enrichBankIdentity(&banks[i])
        } else {
            let info = BankCatalog.info(a.bankCode) ?? BankCatalog.match(name: a.bank)
            let base = info?.name ?? a.bank
            banks.append(BankAccount(name: "\(base) ••\(a.mask)", logo: info?.code ?? Self.shortLogo(a.bank),
                                     colorHex: info?.colorHex ?? "4F7FC4", type: a.type, mask: a.mask, balance: a.balance,
                                     bankCode: info?.code ?? a.bankCode, ifsc: a.ifsc, branch: a.branch, tier: a.tier))
            // Anchor a freshly-created account too, so post-period transactions (already ingested from
            // alerts) are reconstructed onto the statement closing rather than being silently dropped.
            if a.balance != 0, let asOf = a.asOf { setBalanceAnchor(mask: a.mask, balance: a.balance, asOf: asOf) }
        }
    }
    private func ensureBank(mask: String, bankCode: String?) {
        guard !mask.isEmpty, !banks.contains(where: { $0.mask == mask }) else { return }
        let info = BankCatalog.info(bankCode)
        banks.append(BankAccount(name: "\(info?.name ?? "Bank") ••\(mask)", logo: info?.code ?? "BANK",
                                 colorHex: info?.colorHex ?? "4F7FC4", type: "Savings", mask: mask, balance: 0,
                                 bankCode: info?.code))
    }
    private func ensureCard(mask: String, bankCode: String?, cardName: String? = nil) {
        guard !mask.isEmpty, !cards.contains(where: { $0.mask == mask }) else { return }
        let info = BankCatalog.info(bankCode)
        // Only adopt a specific product if it's actually known (from a statement). Never guess a
        // variant from the bank alone — keep it generic until a statement confirms it. The mask
        // keeps names unique across same-product/same-issuer cards.
        if let prod = cardName, let cat = CardCatalog.all.first(where: { $0.name == prod }) {
            cards.append(CreditCard(name: "\(cat.name) ••\(mask)", mask: mask, outstanding: 0, limit: 0, bankCode: bankCode,
                                    network: cat.network, tier: cat.tier, colorHex: cat.gradient.first))
        } else {
            cards.append(CreditCard(name: "\(info?.code ?? info?.name ?? "Card") card ••\(mask)", mask: mask,
                                    outstanding: 0, limit: 0, bankCode: bankCode, colorHex: info?.colorHex))
        }
    }
    private func enrichBankIdentity(_ b: inout BankAccount) {
        if let info = BankCatalog.info(b.bankCode) {
            if b.logo.isEmpty || b.logo == "BANK" { b.logo = info.code }
            if b.colorHex == "4F7FC4" { b.colorHex = info.colorHex }
        }
    }
    /// Resolve the display account for an incoming transaction, or nil when it can't be attributed.
    ///
    /// `mask` is deliberately **empty** for feeds that identify the account only by issuer — a
    /// debit-card alert quotes the *card's* last-4 (which differs from the account's), and an
    /// e-mandate card charge quotes no number at all. Creating an account per card last-4 would
    /// scatter one bank account across several phantom ones, so those resolve by `bankCode`.
    ///
    /// Returning nil is deliberate and the callers drop the row. The alternatives are both worse:
    /// falling back to "the first account" silently books one issuer's spend against another's
    /// balance, and inventing a placeholder account leaves a phantom the user must clean up. A card
    /// charge in particular must **never** fall through to a bank account — an anchored bank balance
    /// re-derives from its transactions, so a stray card row corrupts the figure permanently.
    private func accountName(forMask mask: String, source: TxnSource, bankCode: String? = nil) -> String? {
        if source == .card {
            if !mask.isEmpty, let c = cards.first(where: { $0.mask == mask }) { return c.name }
            if let code = bankCode, let c = cards.first(where: { $0.bankCode == code }) { return c.name }
            return nil
        }
        if !mask.isEmpty, let b = banks.first(where: { $0.mask == mask }) { return b.name }
        if let code = bankCode, let b = banks.first(where: { $0.bankCode == code }) { return b.name }
        return mask.isEmpty ? nil : banks.first?.name
    }

    // MARK: merchant → category rules
    static func ruleKey(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }

    /// Full classification: category + symbol + facet tags + transfer flag + canonical brand.
    /// Order: transfers/refunds → learned rule → brand dictionary → keyword fallback.
    func classify(merchant: String, counterparty: String?, narration: String, income: Bool)
        -> (category: String, symbol: String, tags: [String], transfer: Bool, brand: String?) {
        let text = [merchant, counterparty ?? "", narration].joined(separator: " ")
        if Classifier.isCardBillPayment(text) || (income && Classifier.isCardPaymentCredit(text)) {
            return ("Transfer", "arrow.left.arrow.right", ["Credit card bill"], true, nil)
        }
        var tags: [String] = []
        let refund = income && Classifier.isRefund(text)
        if refund { tags.append("Refund") }
        if income && !refund { return ("Income", "indianrupeesign.circle.fill", [], false, nil) }
        let brand = BrandCatalog.classify(text)
        // learned rule wins for the category; brand still supplies tags
        for key in [counterparty, merchant].compactMap({ $0 }).map(Self.ruleKey) where !key.isEmpty {
            if let cat = merchantRules[key] {
                let sym = categories.first { $0.name == cat }?.symbol ?? Self.symbolFor(cat)
                return (cat, sym, Self.uniq(tags + brand.tags), false, brand.brand)
            }
        }
        if let cat = brand.category {
            let sym = categories.first { $0.name == cat }?.symbol ?? Self.symbolFor(cat)
            return (cat, sym, Self.uniq(tags + brand.tags), false, brand.brand)
        }
        let (cat, sym) = Self.categorize(narration, income: false)
        return (cat, sym, Self.uniq(tags), false, brand.brand)
    }
    func categoryFor(merchant: String, counterparty: String?, narration: String, income: Bool) -> (String, String) {
        let c = classify(merchant: merchant, counterparty: counterparty, narration: narration, income: income)
        return (c.category, c.symbol)
    }
    private static func uniq(_ a: [String]) -> [String] { var s = Set<String>(); return a.filter { s.insert($0).inserted } }
    static func symbolFor(_ cat: String) -> String {
        if let b = baseCategories.first(where: { $0.name == cat }) { return b.symbol }
        switch cat {
        case "Income": return "indianrupeesign.circle.fill"
        case "Transfer": return "arrow.left.arrow.right"; default: return "circle.grid.2x2"
        }
    }
    /// Learn a merchant/counterparty → category mapping and retro-apply to existing txns.
    func learnMerchant(_ rawKey: String, category: String) {
        let key = Self.ruleKey(rawKey); guard !key.isEmpty else { return }
        merchantRules[key] = category
        let sym = categories.first { $0.name == category }?.symbol ?? Self.symbolFor(category)
        for i in txns.indices {
            let k = Self.ruleKey(txns[i].counterparty ?? txns[i].merchant)
            guard k == key, !txns[i].income, txns[i].category != category else { continue }
            txns[i].category = category; txns[i].symbol = sym
        }
        recomputeSpent()
        save()
    }

    // MARK: recurring transfers
    /// How often a recurring charge repeats. Buckets are deliberately wide: real billing dates drift
    /// by a few days (weekends, month lengths, bank holidays).
    enum RecurringCadence: String, CaseIterable {
        case weekly, monthly, quarterly, annual
        /// Nominal gap in days, used to project the next charge.
        var days: Int { switch self { case .weekly: 7; case .monthly: 30; case .quarterly: 91; case .annual: 365 } }
        var label: String { rawValue.capitalized }
        /// Monthly-equivalent multiplier, so cadences fold into one burn figure.
        var perMonth: Double { 30.0 / Double(days) }
        /// The bucket a gap of `d` days falls in, or nil if it matches no cadence.
        static func bucket(days d: Double) -> RecurringCadence? {
            switch d {
            case 6...8: .weekly
            case 26...35: .monthly
            case 85...100: .quarterly
            case 350...380: .annual
            default: nil
            }
        }
    }

    struct RecurringGroup: Identifiable {
        var id: String { key }
        var key: String; var name: String; var count: Int; var total: Double; var lastDate: Date
        var category: String; var linked: Bool
        var cadence: RecurringCadence? = nil
        var confidence: Double = 0
        var expectedAmount: Double = 0
        /// Amounts swing >20% (an electricity autopay, not a fixed subscription): show "~" and keep it
        /// out of the fixed-subscription burn total.
        var variableAmount: Bool = false
        var nextDate: Date? = nil
        /// Two or more cycles have passed with no charge — surfaced as "possibly cancelled" rather
        /// than silently predicted forever.
        var possiblyCancelled: Bool = false
        var muted: Bool = false
        /// A transfer or income group (SIP, self-transfer). Still worth a reminder — "fund the
        /// account" is the most valuable alert — but never counted as subscription spend.
        var isTransfer: Bool = false
    }

    /// Median of a non-empty list; caller guarantees non-empty.
    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Infer a cadence from a group's charge dates. Pure and static so it can be exercised offline.
    /// Needs >= 3 charges and >= 60% of gaps landing in the same bucket.
    static func inferCadence(dates: [Date]) -> (cadence: RecurringCadence, confidence: Double)? {
        let sorted = dates.sorted()
        guard sorted.count >= 3 else { return nil }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) / 86_400 }
        guard !gaps.isEmpty, let cad = RecurringCadence.bucket(days: median(gaps)) else { return nil }
        let hits = gaps.filter { RecurringCadence.bucket(days: $0) == cad }.count
        let confidence = Double(hits) / Double(gaps.count)
        return confidence >= 0.6 ? (cad, confidence) : nil
    }

    /// Next expected charge for a group whose last charge was `last`. Rolls forward at most once when
    /// the projected date has already passed; returns nil once 2+ cycles have elapsed (likely cancelled).
    static func projectNext(last: Date, cadence: RecurringCadence, now: Date = Date()) -> Date? {
        let cal = Calendar.current
        guard let first = cal.date(byAdding: .day, value: cadence.days, to: last) else { return nil }
        if first >= now { return first }
        guard let second = cal.date(byAdding: .day, value: cadence.days, to: first) else { return nil }
        return second >= now ? second : nil
    }

    var recurringGroups: [RecurringGroup] {
        // Include transfers/income here (they're excluded from spend totals downstream, not from
        // detection) so SIPs and self-transfers can still produce reminders.
        let candidates = txns.filter { spendContribution($0) > 0 || $0.transfer }
        let groups = Dictionary(grouping: candidates) { Self.ruleKey($0.counterparty ?? $0.merchant) }
        let now = Date()
        return groups.compactMap { key, items -> RecurringGroup? in
            guard key.count > 1, items.count >= 3 else { return nil }
            let amounts = items.map { abs($0.amount) }
            let total = amounts.reduce(0, +)
            let last = items.map(\.date).max() ?? now
            var g = RecurringGroup(key: key, name: items.first?.merchant ?? key, count: items.count,
                                   total: total, lastDate: last,
                                   category: items.first?.category ?? "Other",
                                   linked: merchantRules[key] != nil)
            g.muted = mutedRecurringKeys.contains(key)
            g.isTransfer = items.contains { $0.transfer } || items.first?.category == "Income"
            // Price rises are normal, so the expected amount is the median of the last 3 charges
            // rather than anything that assumes equal amounts.
            let recent = items.sorted { $0.date > $1.date }.prefix(3).map { abs($0.amount) }
            g.expectedAmount = Self.median(Array(recent))
            if g.expectedAmount > 0 {
                let spread = (amounts.max() ?? 0) - (amounts.min() ?? 0)
                g.variableAmount = spread / g.expectedAmount > 0.2
            }
            if let (cad, conf) = Self.inferCadence(dates: items.map(\.date)) {
                g.cadence = cad; g.confidence = conf
                g.nextDate = Self.projectNext(last: last, cadence: cad, now: now)
                g.possiblyCancelled = g.nextDate == nil
            }
            return g
        }.sorted { $0.count > $1.count }
    }

    /// Predicted charges landing within `days`, soonest first. Muted and cancelled groups drop out.
    func upcomingCharges(within days: Int = 7) -> [RecurringGroup] {
        let cutoff = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return recurringGroups
            .filter { !$0.muted && !$0.possiblyCancelled }
            .filter { g in g.nextDate.map { $0 <= cutoff } ?? false }
            .sorted { ($0.nextDate ?? .distantFuture) < ($1.nextDate ?? .distantFuture) }
    }

    /// Fixed-subscription burn per month. Excludes variable-amount bills and transfers/SIPs — a
    /// 50k SIP is not a subscription cost — and excludes muted groups.
    var subscriptionBurn: Double {
        recurringGroups
            .filter { !$0.muted && !$0.possiblyCancelled && !$0.variableAmount && !$0.isTransfer }
            .compactMap { g in g.cadence.map { g.expectedAmount * $0.perMonth } }
            .reduce(0, +)
    }

    /// Variable recurring bills (electricity, phone) per month — reported separately from the fixed burn.
    var recurringBillsBurn: Double {
        recurringGroups
            .filter { !$0.muted && !$0.possiblyCancelled && $0.variableAmount && !$0.isTransfer }
            .compactMap { g in g.cadence.map { g.expectedAmount * $0.perMonth } }
            .reduce(0, +)
    }

    func toggleRecurringMute(_ key: String) {
        if mutedRecurringKeys.contains(key) { mutedRecurringKeys.remove(key) } else { mutedRecurringKeys.insert(key) }
        save()
        rescheduleRecurringReminders()
    }

    /// Cancel-and-reschedule as a set, so a recompute can't leave orphaned notifications behind.
    func rescheduleRecurringReminders() {
        let upcoming = upcomingCharges(within: 30)
        NotificationManager.scheduleRecurring(upcoming.compactMap { g in
            g.nextDate.map { (key: g.key, name: g.name, date: $0,
                              amount: g.variableAmount ? nil : g.expectedAmount) }
        })
    }

    private static func shortLogo(_ bank: String) -> String {
        String(bank.components(separatedBy: " ").first?.prefix(4) ?? "BANK").uppercased()
    }
    private static func prettyMerchant(_ narration: String) -> String {
        let stop = ["UPI", "POS", "NEFT", "IMPS", "ACH", "BILLPAY", "MANDATE", "ATW", "ECS", "TXN", "REF"]
        let parts = narration.uppercased().split(whereSeparator: { "/ -*".contains($0) })
            .map(String.init).filter { !stop.contains($0) && !$0.allSatisfy(\.isNumber) && $0.count > 1 }
        return (parts.first.map { $0.capitalized } ?? narration).trimmingCharacters(in: .whitespaces)
    }
    /// Keyword → (category name, SF Symbol). Falls back to "Other".
    static func categorize(_ narration: String, income: Bool) -> (String, String) {
        if income { return ("Income", "indianrupeesign.circle.fill") }
        let n = narration.uppercased()
        func has(_ ks: [String]) -> Bool { ks.contains { n.contains($0) } }
        if has(["SWIGGY", "ZOMATO", "RESTAURANT", "CAFE", "FOOD"]) { return ("Eating out", "fork.knife") }
        if has(["BIGBASKET", "GROCER", "DMART", "SUPERMARKET", "BLINKIT", "ZEPTO"]) { return ("Groceries", "cart.fill") }
        if has(["UBER", "OLA", "FUEL", "PETROL", "METRO", "IRCTC", "RIDE"]) { return ("Transport", "car.fill") }
        if has(["AMAZON", "FLIPKART", "MYNTRA", "SHOP", "NYKAA", "AJIO"]) { return ("Shopping", "bag.fill") }
        if has(["NETFLIX", "SPOTIFY", "PRIME", "HOTSTAR", "SUBSCRIPTION", "YOUTUBE"]) { return ("Subscriptions", "play.rectangle.fill") }
        if has(["ELECTRICITY", "RENT", "KSEB", "BILL", "WATER", "GAS", "BROADBAND"]) { return ("Bills & Utilities", "bolt.fill") }
        if has(["PHARMACY", "APOLLO", "HOSPITAL", "MEDIC", "CLINIC", "HEALTH"]) { return ("Health", "heart.fill") }
        return ("Other", "circle.grid.2x2")
    }

    // MARK: refresh derived stored collections
    private func refreshMilestones() {
        let nw = liquidNetWorth
        var activeSet = false
        milestones = milestones.sorted { $0.amount < $1.amount }.map { m in
            var m = m
            if nw >= m.amount { m.reached = true; m.active = false; m.pct = 1; m.tag = "Reached" }
            else if !activeSet { m.reached = false; m.active = true; activeSet = true
                m.pct = m.amount > 0 ? min(1, nw / m.amount) : 0; m.tag = "In progress" }
            else { m.reached = false; m.active = false; m.pct = 0; m.tag = "Locked" }
            return m
        }
    }
    private func refreshBadges() {
        func set(_ label: String, _ earned: Bool) {
            if let i = badges.firstIndex(where: { $0.label == label }) { badges[i].earned = earned }
        }
        set("First lakh", liquidNetWorth >= 100_000)
        set("On budget", !categories.isEmpty && categories.allSatisfy { !$0.over })
        set("No debt", !cards.isEmpty && cards.allSatisfy { $0.outstanding <= 0 })
        set("Goal hit", goals.contains { $0.status == .achieved })
        set("Investor", !deposits.isEmpty)
        set("Streak", streakMonths >= 3)
    }
    private func recordNetWorthPoint() {
        let nw = liquidNetWorth
        let today = ISO8601DateFormatter.dayString(Date())
        let last = UserDefaults.standard.string(forKey: nwDayKey)
        if nwHistory.isEmpty { nwHistory = [nw] }
        else if last == today { nwHistory[nwHistory.count - 1] = nw }
        else { nwHistory.append(nw); if nwHistory.count > 90 { nwHistory.removeFirst(nwHistory.count - 90) } }
        UserDefaults.standard.set(today, forKey: nwDayKey)
    }

    // MARK: persistence
    static let schemaVersion = 3
    struct Persist: Codable {
        var schemaVersion = Store.schemaVersion
        var categories: [BudgetCategory] = []
        var txns: [Txn] = []
        var banks: [BankAccount] = []
        var cards: [CreditCard] = []
        var deposits: [Deposit] = []
        var goals: [Goal] = []
        var milestones: [Milestone] = []
        var badges: [Badge] = []
        var incomeStreams: [IncomeStream] = []
        var investments: [Investment] = []
        var loans: [Loan] = []
        var statements: [StatementRecord] = []
        var conflicts: [DataConflict] = []
        var nwHistory: [Double] = []
        var fxRates: [String: Double] = ["INR": 1]
        var taxProfile = TaxProfile()
        var payslips: [Payslip] = []
        var advanceTaxPaidStages: [Int] = []
        var merchantRules: [String: String] = [:]
        var mutedRecurringKeys: [String] = []

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            categories = c.decode(.categories, default: [])
            txns       = c.decode(.txns, default: [])
            banks      = c.decode(.banks, default: [])
            cards      = c.decode(.cards, default: [])
            deposits   = c.decode(.deposits, default: [])
            goals      = c.decode(.goals, default: [])
            milestones = c.decode(.milestones, default: [])
            badges     = c.decode(.badges, default: [])
            incomeStreams = c.decode(.incomeStreams, default: [])
            investments = c.decode(.investments, default: [])
            loans      = c.decode(.loans, default: [])
            statements = c.decode(.statements, default: [])
            conflicts  = c.decode(.conflicts, default: [])
            nwHistory  = c.decode(.nwHistory, default: [])
            fxRates    = c.decode(.fxRates, default: ["INR": 1])
            taxProfile = c.decode(.taxProfile, default: TaxProfile())
            payslips   = c.decode(.payslips, default: [])
            advanceTaxPaidStages = c.decode(.advanceTaxPaidStages, default: [])
            merchantRules = c.decode(.merchantRules, default: [:])
            mutedRecurringKeys = c.decode(.mutedRecurringKeys, default: [])
        }
    }

    private func makePersist() -> Persist {
        var p = Persist()
        p.categories = categories; p.txns = txns; p.banks = banks; p.cards = cards
        p.deposits = deposits; p.goals = goals; p.milestones = milestones; p.badges = badges
        p.incomeStreams = incomeStreams; p.investments = investments; p.nwHistory = nwHistory
        p.loans = loans
        p.statements = statements; p.conflicts = conflicts
        p.fxRates = fxRates; p.taxProfile = taxProfile; p.payslips = payslips
        p.advanceTaxPaidStages = Array(advanceTaxPaidStages)
        p.merchantRules = merchantRules
        p.mutedRecurringKeys = Array(mutedRecurringKeys)
        return p
    }

    private func apply(_ p: Persist) {
        categories = p.categories; txns = p.txns; banks = p.banks; cards = p.cards
        deposits = p.deposits; goals = p.goals; milestones = p.milestones; badges = p.badges
        incomeStreams = p.incomeStreams; investments = p.investments; nwHistory = p.nwHistory
        loans = p.loans
        statements = p.statements; conflicts = p.conflicts
        fxRates = p.fxRates.isEmpty ? ["INR": 1] : p.fxRates
        taxProfile = p.taxProfile; payslips = p.payslips
        advanceTaxPaidStages = Set(p.advanceTaxPaidStages)
        merchantRules = p.merchantRules
        mutedRecurringKeys = Set(p.mutedRecurringKeys)
        if milestones.isEmpty { milestones = Self.defaultMilestones() }
        if badges.isEmpty { badges = Self.defaultBadges() }
        migrateRentBills()
        ensureBaseCategories()
        dedupeAccountNames()
    }

    // MARK: maintained base categories
    /// Canonical base taxonomy — always present, can't be deleted/renamed (budget + icon editable).
    static let baseCategories: [(name: String, symbol: String, color: String, kind: CategoryKind)] = [
        ("Eating out", "fork.knife", "6E9BD8", .wants),
        ("Online food delivery", "takeoutbag.and.cup.and.straw.fill", "7FC4A3", .wants),
        ("Groceries", "cart.fill", "5BA585", .needs),
        ("Transport", "car.fill", "4F7FC4", .needs),
        ("Travel", "airplane", "9AA7BE", .wants),
        ("Fuel", "fuelpump.fill", "6E9BD8", .needs),
        ("Shopping", "bag.fill", "7FC4A3", .wants),
        ("Subscriptions", "play.rectangle.fill", "5BA585", .wants),
        ("Entertainment", "popcorn.fill", "4F7FC4", .wants),
        ("Bills & Utilities", "bolt.fill", "9AA7BE", .needs),
        ("Insurance", "shield.lefthalf.filled", "6E9BD8", .needs),
        ("Tax", "building.columns.fill", "9AA7BE", .needs),
        ("EMI & Loans", "banknote.fill", "7FC4A3", .needs),
        ("Health", "heart.fill", "5BA585", .needs),
        ("Education", "graduationcap.fill", "4F7FC4", .needs),
        ("Family", "person.2.fill", "9AA7BE", .needs),
        ("Investments", "chart.line.uptrend.xyaxis", "6E9BD8", .investments),
        ("Other", "circle.grid.2x2", "9AA7BE", .wants),
    ]
    /// One-time rename of the old "Rent & Bills" category → "Bills & Utilities" (idempotent).
    func migrateRentBills() {
        let old = "Rent & Bills", new = "Bills & Utilities"
        guard categories.contains(where: { $0.name == old }) || txns.contains(where: { $0.category == old }) else { return }
        if let i = categories.firstIndex(where: { $0.name == old }) {
            if categories.contains(where: { $0.name == new }) { categories.remove(at: i) }   // base already seeded
            else { categories[i].name = new }
        }
        for j in txns.indices where txns[j].category == old { txns[j].category = new }
        for (k, v) in merchantRules where v == old { merchantRules[k] = new }
    }

    /// Re-run the brand library over existing transactions, updating category/tags — but only
    /// where the library actually matches, never overriding manual rules / transfers / income.
    func recategorizeAll() {
        for i in txns.indices {
            let t = txns[i]
            guard !t.transfer, !t.income else { continue }
            if merchantRules[Self.ruleKey(t.counterparty ?? t.merchant)] != nil { continue }
            let b = BrandCatalog.classify([t.merchant, t.counterparty ?? ""].joined(separator: " "))
            guard let cat = b.category else { continue }
            txns[i].category = cat
            txns[i].symbol = categories.first { $0.name == cat }?.symbol ?? Self.symbolFor(cat)
            txns[i].tags = Self.uniq(t.tags + b.tags)
        }
        recomputeSpent(); save()
    }

    /// Add any missing base category (preserving the user's edits to existing same-named ones).
    func ensureBaseCategories() {
        for b in Self.baseCategories {
            if let i = categories.firstIndex(where: { $0.name == b.name }) {
                if !categories[i].isSystem { categories[i].isSystem = true }   // adopt existing same-named as the base
            } else {
                categories.append(BudgetCategory(name: b.name, symbol: b.symbol, spent: 0, plan: 0, color: b.color, isSystem: true, kind: b.kind))
            }
        }
    }

    /// Wipe all financial records (accounts, cards, transactions, goals, income, rules) from this
    /// device. Profile name, net-worth target and preferences are kept; gamification is re-seeded.
    /// Full store-side reset: wipes all data, resets preferences to defaults, deletes owned
    /// files (user images, widget snapshot) and persisted keys. Auto-backups are intentionally
    /// kept (the user's recovery option). Gmail/Setu are reset by their own managers.
    func clearAll() {
        categories = []; txns = []; banks = []; cards = []; deposits = []; goals = []
        investments = []; incomeStreams = []; nwHistory = []; loans = []
        statements = []; conflicts = []
        taxProfile = TaxProfile(); payslips = []; advanceTaxPaidStages = []; merchantRules = [:]
        mutedRecurringKeys = []
        fxRates = ["INR": 1]
        milestones = Self.defaultMilestones()
        badges = Self.defaultBadges()
        ensureBaseCategories()

        // reset preferences to defaults (didSet persists the defaults)
        userName = ""
        netWorthTarget = 5_000_000
        preferStatementImport = false
        accountAggregatorEnabled = false
        notificationsEnabled = false; NotificationManager.setEnabled(false)
        autoBackupEnabled = true

        // remove owned persisted keys + files
        let d = UserDefaults.standard
        d.removeObject(forKey: key); d.removeObject(forKey: key + "_corrupt_backup"); d.removeObject(forKey: nwDayKey)
        let fm = FileManager.default
        if let imgs = try? fm.contentsOfDirectory(at: LocalImage.dir, includingPropertiesForKeys: nil) {
            for u in imgs where u.lastPathComponent.hasPrefix("img_") { try? fm.removeItem(at: u) }
        }
        try? fm.removeItem(at: WTMShared.snapshotURL)

        save()
    }

    func save() {
        refreshMilestones(); refreshBadges(); recordNetWorthPoint()
        if let d = try? JSONEncoder().encode(makePersist()) { UserDefaults.standard.set(d, forKey: key) }
        publishSnapshot()
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key) else { firstRun(); return }
        do { apply(try JSONDecoder().decode(Persist.self, from: d)) }
        catch {
            UserDefaults.standard.set(d, forKey: key + "_corrupt_backup")
            firstRun()
        }
    }

    // MARK: - Backup / restore (device migration). NO Keychain secrets included.
    struct BackupBundle: Codable {
        var schemaVersion = Store.schemaVersion
        var exportedAt = Date()
        var data = Persist()
        var userName = ""
        var netWorthTarget = 5_000_000.0
        var preferStatementImport = false
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = c.decode(.schemaVersion, default: Store.schemaVersion)
            exportedAt = c.decode(.exportedAt, default: Date())
            data = c.decode(.data, default: Persist())
            userName = c.decode(.userName, default: "")
            netWorthTarget = c.decode(.netWorthTarget, default: 5_000_000)
            preferStatementImport = c.decode(.preferStatementImport, default: false)
        }
    }

    private static var backupCoder: (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    func exportBundle() -> Data {
        var b = BackupBundle()
        b.data = makePersist(); b.userName = userName
        b.netWorthTarget = netWorthTarget; b.preferStatementImport = preferStatementImport
        return (try? Self.backupCoder.0.encode(b)) ?? Data()
    }

    @discardableResult
    func importBundle(_ data: Data, replace: Bool) -> Bool {
        guard let b = try? Self.backupCoder.1.decode(BackupBundle.self, from: data) else { return false }
        if replace { apply(b.data) } else { mergeIn(b.data) }
        userName = b.userName
        netWorthTarget = b.netWorthTarget > 0 ? b.netWorthTarget : netWorthTarget
        preferStatementImport = b.preferStatementImport
        // Swapping the txn set invalidates every derived total; this also cascades to anchored
        // bank balances and asset-backed goal progress. Idempotent on a self-consistent bundle.
        recomputeSpent()
        save()
        return true
    }

    /// Union by id (txns also dedup by externalId).
    private func mergeIn(_ p: Persist) {
        func union<T: Identifiable>(_ base: inout [T], _ extra: [T]) {
            let ids = Set(base.map { $0.id }); base += extra.filter { !ids.contains($0.id) }
        }
        union(&categories, p.categories); union(&banks, p.banks); union(&cards, p.cards)
        union(&deposits, p.deposits); union(&goals, p.goals); union(&incomeStreams, p.incomeStreams)
        union(&investments, p.investments); union(&loans, p.loans)
        let extIds = Set(txns.compactMap(\.externalId)); let ids = Set(txns.map(\.id))
        txns += p.txns.filter { !ids.contains($0.id) && !($0.externalId.map { extIds.contains($0) } ?? false) }
    }

    /// First launch: NO financial data. Only the milestone ladder + badge templates
    /// (both derived against real balances, starting at 0 / locked).
    private func firstRun() {
        milestones = Self.defaultMilestones()
        badges = Self.defaultBadges()
        ensureBaseCategories()
        save()
    }

    private static func defaultMilestones() -> [Milestone] {
        [100_000, 500_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000].map {
            Milestone(amount: $0, name: milestoneName($0), tag: "Locked", reached: false, active: false, pct: 0)
        }
    }
    private static func milestoneName(_ a: Double) -> String {
        switch a {
        case 100_000: return "First lakh"
        case 500_000: return "Five lakh"
        case 1_000_000: return "Ten lakh"
        case 2_500_000: return "Quarter crore"
        case 5_000_000: return "Half crore"
        default: return "First crore"
        }
    }
    private static func defaultBadges() -> [Badge] {
        [ Badge(symbol: "flame.fill", label: "Streak", earned: false),
          Badge(symbol: "checkmark.seal.fill", label: "On budget", earned: false),
          Badge(symbol: "banknote.fill", label: "First lakh", earned: false),
          Badge(symbol: "chart.line.uptrend.xyaxis", label: "Investor", earned: false),
          Badge(symbol: "trophy.fill", label: "Goal hit", earned: false),
          Badge(symbol: "crown.fill", label: "No debt", earned: false) ]
    }
}

private extension ISO8601DateFormatter {
    static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
