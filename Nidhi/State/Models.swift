import SwiftUI

// MARK: - Tabs
enum Tab: String, CaseIterable, Identifiable {
    case home, plan, insights, goals, wealth, income
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .plan: return "Plan"
        case .insights: return "Insights"
        case .goals: return "Goals"
        case .wealth: return "Wealth"
        case .income: return "Income"
        }
    }
}

// MARK: - Budget cap period
/// The window a category's `plan` (cap) applies over. Most spends are monthly, but some — insurance,
/// subscriptions billed yearly, school fees — are naturally quarterly / annual / custom-length.
enum BudgetPeriod: String, Codable, CaseIterable, Identifiable {
    case monthly, quarterly, annual, custom
    var id: String { rawValue }
    /// Cycle length in months (custom is handled via `BudgetCategory.customMonths`).
    var months: Int { switch self { case .monthly: 1; case .quarterly: 3; case .annual: 12; case .custom: 1 } }
    var label: String { switch self { case .monthly: "Monthly"; case .quarterly: "Quarterly"; case .annual: "Annual"; case .custom: "Custom" } }
    /// Short noun for "this <noun>" / "per <noun>".
    var noun: String { switch self { case .monthly: "month"; case .quarterly: "quarter"; case .annual: "year"; case .custom: "period" } }
}

/// Which budget bucket a category falls under — drives whether it counts toward the app's
/// cross-category "total spend" figures (Investments never does; it has its own cap/progress
/// bar but isn't spend).
enum CategoryKind: String, Codable, CaseIterable, Identifiable {
    case needs, wants, investments
    var id: String { rawValue }
    var label: String { switch self { case .needs: "Need"; case .wants: "Want"; case .investments: "Investment" } }
}

// MARK: - Category (budget)
struct BudgetCategory: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String        // SF Symbol
    var spent: Double         // recomputed: spend within the current cap cycle (see Store.recomputeSpent)
    var plan: Double          // the cap, expressed per cycle (e.g. ₹24,000 / year for annual insurance)
    var color: String         // hex for icon tint
    var isSystem: Bool = false // a maintained base category — can't be deleted/renamed
    var period: BudgetPeriod = .monthly   // window the cap applies over
    var customMonths: Int = 1             // cycle length when period == .custom
    var anchor: Date? = nil               // cycle start (e.g. insurance renewal); nil → financial-year start
    var kind: CategoryKind = .needs       // Need / Want / Investment facet
    /// "YYYY-MM" → the `monthlyPlan` in force during that month. Written by `Store.snapshotCaps()`
    /// so a past month is judged against the cap that applied then, not today's. Lives inside the
    /// category (not a name-keyed map on Store) so it survives renames; deleting a category drops
    /// its history, same as spend attribution — deliberately no tombstones.
    var capHistory: [String: Double] = [:]

    /// Effective cycle length in months (≥ 1).
    var periodMonths: Int { period == .custom ? max(1, customMonths) : period.months }
    /// The cap normalised to a per-month figure, so non-monthly caps still fold into the monthly overview.
    var monthlyPlan: Double { plan / Double(periodMonths) }

    /// The per-month cap for `key` ("YYYY-MM"). Falls back to the live cap, so months recorded
    /// before this feature existed behave exactly as they did before — no migration needed.
    func plan(forMonth key: String) -> Double { capHistory[key] ?? monthlyPlan }

    var pct: Double { plan > 0 ? spent / plan : 0 }
    var left: Double { plan - spent }
    var over: Bool { spent > plan }
    // zen: slate caution (not red), calm blue near-limit, sage green ok
    var barColorHex: String { over ? "9AA7BE" : (pct > 0.85 ? "6E9BD8" : "7FC4A3") }
}

// MARK: - Transaction
enum TxnSource: String, Codable { case bank, card, unknown }

struct Txn: Identifiable, Codable, Hashable {
    var id = UUID()
    var merchant: String
    var symbol: String
    var category: String
    var account: String
    var amount: Double        // negative = spend, positive = income
    var date: Date
    var externalId: String? = nil   // stable id from the bank/AA feed, for dedup
    var source: TxnSource = .unknown
    var counterparty: String? = nil // VPA / payee / account — key for recurring + rules
    var statementId: String? = nil  // set once confirmed/enriched by a statement (prevents re-match)
    var statementRecordId: UUID? = nil // the StatementRecord this txn was ingested from (cascade delete)
    var needsReview: Bool = false   // a parser couldn't resolve date/amount/merchant — see DataConflict
    var tags: [String] = []         // facet labels (Entertainment, Tech, …) + "Refund" + "Add-on"
    var transfer: Bool = false      // CC bill payment / self-transfer — excluded from spend & income
    var cardholder: String? = nil   // add-on cardholder who made this spend; nil = primary cardholder
    var reward: Double? = nil       // loyalty reward earned on this spend (points / miles / coins / cashback)
    var rewardCurrency: String? = nil // unit for `reward`, varies by card (e.g. "Reward Points", "EDGE Miles", "Cashback", "Scapia Coins")
    var forexCurrency: String? = nil  // original currency of an international spend (e.g. "EUR"); nil = domestic
    var forexAmount: Double? = nil    // amount in the original currency; `amount` holds the INR value
    var loanId: UUID? = nil           // the Loan this EMI debit services (set by Store.applyLoanLinks)
    var income: Bool { amount > 0 }
    var isRefund: Bool { tags.contains("Refund") }
    var isInternational: Bool { forexCurrency != nil || tags.contains("International") }
    /// "EUR 150.06" style label for an international spend, else nil.
    var forexLabel: String? {
        guard let c = forexCurrency, let a = forexAmount else { return nil }
        return "\(c) \(NumberFormatter.localizedString(from: NSNumber(value: a), number: .decimal))"
    }
    /// "+540 Reward Points" style label when this spend earned a reward, else nil.
    var rewardLabel: String? {
        guard let r = reward, r != 0 else { return nil }
        let n = NumberFormatter.localizedString(from: NSNumber(value: r), number: .decimal)
        return "+\(n) \(rewardCurrency ?? "reward")"
    }
}

// MARK: - Bank account
struct BankAccount: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var logo: String          // short monogram e.g. HDFC
    var colorHex: String
    var type: String
    var mask: String
    var balance: Double
    var bankCode: String? = nil
    var ifsc: String? = nil
    var branch: String? = nil
    var tier: String? = nil
    var imageRef: String? = nil   // user-supplied logo (file name in Documents or URL)
    /// Balance reconstruction anchor: the last authoritative reading (`balanceAnchor`) and the moment
    /// it was true (`balanceAsOf`, normalised to end-of-day). The displayed `balance` is always
    /// *derived* = balanceAnchor + Σ(txn.amount for txns dated after balanceAsOf), so the latest
    /// reading always wins and a missed/duplicate txn can't permanently corrupt the figure.
    /// nil ⇒ no anchor yet (manual / AA accounts) — `balance` is then used verbatim.
    var balanceAnchor: Double? = nil
    var balanceAsOf: Date? = nil
}

// MARK: - Credit card
struct CreditCard: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var mask: String
    var outstanding: Double
    var limit: Double
    var bankCode: String? = nil
    var network: String? = nil
    var tier: String? = nil
    var colorHex: String? = nil
    var imageRef: String? = nil
    var rewardKind: String? = nil    // Points / Miles / Coins / Cashback
    var rewardBalance: Double? = nil
    // Current statement's payment figures (from the last imported statement). All optional so
    // pre-feature cards decode cleanly; the due chip/reminders simply stay hidden when absent.
    var totalDue: Double? = nil
    var minDue: Double? = nil
    var dueDate: Date? = nil
    /// Set when a bill payment ≥ minDue lands after the statement date — silences the reminder
    /// and flips the chip to "Paid" without waiting for the next statement.
    var dueClearedAt: Date? = nil

    var util: Int { limit > 0 ? Int((outstanding / limit * 100).rounded()) : 0 }

    /// Whole days from today (start-of-day) to the due date; negative once overdue. nil = no due date.
    var daysUntilDue: Int? {
        guard let dueDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: dueDate)).day
    }
    /// True once a qualifying payment has cleared the current statement's due.
    var duePaid: Bool {
        guard let dueClearedAt, let dueDate else { return false }
        return dueClearedAt >= dueDate.addingTimeInterval(-45 * 86400)   // cleared for this cycle
    }
    /// A short "due in N days" / "due today" / "overdue" label, or "Paid". nil when no due date.
    var dueChip: (text: String, overdue: Bool)? {
        guard let d = daysUntilDue else { return nil }
        if duePaid { return ("Paid", false) }
        if d < 0 { return ("Overdue", true) }
        if d == 0 { return ("Due today", true) }
        if d == 1 { return ("Due tomorrow", d <= 3) }
        return ("Due in \(d) days", d <= 3)
    }
    /// Cards worth nudging on Home: a real due date, not yet paid, within 5 days (incl. overdue).
    var needsDueAttention: Bool {
        guard let d = daysUntilDue, !duePaid else { return false }
        return d <= 5
    }
    var rewardLabel: String? {
        guard let k = rewardKind, let b = rewardBalance else { return nil }
        let g = NumberFormatter.localizedString(from: NSNumber(value: b), number: .decimal)
        switch k.lowercased() {
        case "cashback": return "₹\(g) cashback"
        case "miles": return "\(g) miles"
        case "coins": return "\(g) coins"
        default: return "\(g) pts"
        }
    }
    var utilColorHex: String { util > 70 ? "9AA7BE" : (util > 40 ? "6E9BD8" : "7FC4A3") }
}

// MARK: - Deposit (FD / RD)
struct Deposit: Identifiable, Codable, Hashable {
    var id = UUID()
    var bank: String
    var tag: String           // "FD" / "RD"
    var symbol: String
    var rate: Double          // interest %
    var current: Double       // current value
    var startDate: Date
    var maturityDate: Date
    var identifier: String? = nil   // deposit account number — for de-dup on re-import

    var progress: Double {
        let total = maturityDate.timeIntervalSince(startDate)
        return total > 0 ? min(1, max(0, Date().timeIntervalSince(startDate) / total)) : 0
    }
    var rateText: String {
        let r = (rate * 100).rounded() / 100
        return (r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r)) + "%"
    }
    var maturesText: String { maturityDate.formatted(.dateTime.month(.abbreviated).year()) }
    var sub: String { tag == "RD" ? "Recurring deposit" : "Fixed deposit" }
}

// MARK: - Loan (liability)
/// A manual principal adjustment — a prepayment / part-payment / foreclosure amount knocked off
/// the schedule on `date`. Prepayments break pure amortisation, so they're applied as segment
/// boundaries by `LoanMath`. (Deliberately a manual-entry hook, not a statement parser.)
struct LoanAdjustment: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date = Date()
    var amount: Double = 0        // principal knocked off (positive)
    var note: String = ""
}

/// A borrowing — home / car / personal / education loan. Net worth subtracts its **amortised**
/// outstanding, never the sum of its EMI transactions: those debits already left the bank balance,
/// so counting them here too would subtract the same rupee twice (see `Store.netWorth`).
struct Loan: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var lender: String = ""
    var principal: Double = 0          // sanctioned principal
    var rate: Double = 0               // annual reducing-balance rate, %
    var emi: Double = 0
    var startDate: Date = Date()       // schedule start (disbursal); the first EMI falls due a month later
    var tenureMonths: Int = 0
    var mask: String = ""              // last 4 of the loan account number
    var counterpartyKey: String = ""   // Store.ruleKey of the linked EMI counterparty / recurring group
    var symbol: String = "house.fill"
    var principalAdjustments: [LoanAdjustment] = []
    /// Manual recalibration anchor — the cheap answer to floating rates and statement-stated
    /// balances, mirroring the bank balance-anchor idiom: amortisation restarts from
    /// `anchorPrincipal` as of `anchorAsOf` instead of from the original sanction.
    var anchorPrincipal: Double? = nil
    var anchorAsOf: Date? = nil
    var closed: Bool = false           // fully repaid / foreclosed — kept for history, excluded from net worth

    /// Common loan kinds, only used to seed a sensible icon in the add sheet.
    static let symbols: [(label: String, symbol: String)] = [
        ("Home", "house.fill"), ("Car", "car.fill"), ("Personal", "person.fill"),
        ("Education", "graduationcap.fill"), ("Gold", "seal.fill"), ("Other", "banknote.fill"),
    ]
}

extension Loan {
    /// Where amortisation is measured from — the recalibration anchor when set, else the sanction.
    var schedulePrincipal: Double { anchorPrincipal ?? principal }
    var scheduleStart: Date { anchorAsOf ?? startDate }

    /// EMIs already served before the anchor, so the tenure cap stays honest after a recalibration.
    func servedBeforeAnchor(_ calendar: Calendar) -> Int {
        anchorAsOf.map { LoanMath.paymentsElapsed(from: startDate, to: $0, calendar: calendar) } ?? 0
    }

    /// Scheduled outstanding principal at `asOf` (prepayments applied, capped at the tenure).
    /// `asOf` is always injected — this stays a pure function of its inputs.
    func outstanding(asOf: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Double {
        if closed { return 0 }
        let served = servedBeforeAnchor(calendar)
        if tenureMonths > 0, served >= tenureMonths { return 0 }
        let cap = tenureMonths > 0 ? tenureMonths - served : 0   // 0 ⇒ no cap (open-ended tenure)
        return LoanMath.outstanding(principal: schedulePrincipal, annualRate: rate, emi: emi,
                                    tenureMonths: cap, start: scheduleStart, asOf: asOf,
                                    adjustments: principalAdjustments.map { (date: $0.date, amount: $0.amount) },
                                    calendar: calendar)
    }
    /// EMIs the schedule says should have been paid by `asOf` (capped at the tenure).
    func scheduledPayments(asOf: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        let elapsed = LoanMath.paymentsElapsed(from: startDate, to: asOf, calendar: calendar)
        return tenureMonths > 0 ? min(tenureMonths, elapsed) : elapsed
    }
    func monthsLeft(asOf: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        LoanMath.monthsRemaining(tenureMonths: tenureMonths, start: startDate, asOf: asOf, calendar: calendar)
    }
    /// Share of the *principal* repaid, 0…1 — what the user means by "how far through am I".
    func paidFraction(asOf: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Double {
        guard principal > 0 else { return 0 }
        return min(1, max(0, (principal - outstanding(asOf: asOf, calendar: calendar)) / principal))
    }
    var displayName: String { name.isEmpty ? (lender.isEmpty ? "Loan" : "\(lender) loan") : name }
    var rateText: String {
        let r = (rate * 100).rounded() / 100
        return (r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r)) + "%"
    }
    var tenureText: String {
        guard tenureMonths > 0 else { return "Open-ended" }
        let y = tenureMonths / 12, m = tenureMonths % 12
        if y == 0 { return "\(m)mo" }
        return m == 0 ? "\(y)y" : "\(y)y \(m)mo"
    }
}

// MARK: - Investment (stocks & mutual funds)
enum InvestmentKind: String, Codable, CaseIterable {
    case stock, etf, mutualFund
    var label: String {
        switch self { case .stock: return "Stock"; case .etf: return "ETF"; case .mutualFund: return "Mutual fund" }
    }
    var symbol: String {
        switch self { case .stock: return "chart.bar.xaxis"; case .etf: return "chart.bar.doc.horizontal"; case .mutualFund: return "chart.pie.fill" }
    }
    var idLabel: String {
        switch self { case .stock: return "Stock symbol"; case .etf: return "ETF symbol"; case .mutualFund: return "AMFI scheme code" }
    }
    /// Stocks & ETFs trade on exchanges (Yahoo); mutual funds use AMFI (India).
    var usesMarket: Bool { self != .mutualFund }
    /// Yahoo `quoteType` to filter search results.
    var yahooType: String { self == .etf ? "ETF" : "EQUITY" }
}

struct Investment: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: InvestmentKind
    var units: Double
    var avgCost: Double        // per unit
    var identifier: String     // NSE symbol or AMFI scheme code
    var lastPrice: Double      // cached latest quote/NAV
    var lastUpdated: Date?

    var invested: Double { units * avgCost }
    var currentValue: Double { units * (lastPrice > 0 ? lastPrice : avgCost) }
    var pnl: Double { currentValue - invested }
    var pnlPct: Double { invested > 0 ? pnl / invested * 100 : 0 }
}

// MARK: - Goal
enum GoalStatus: String, Codable, CaseIterable {
    case onTrack = "On track"
    case atRisk  = "At risk"
    case paused  = "Paused"
    case achieved = "Achieved"
    var colorHex: String {
        switch self {
        case .onTrack: return "7FC4A3"   // sage
        case .atRisk:  return "9AA7BE"   // slate caution (not red)
        case .paused:  return "9AA3B2"   // muted
        case .achieved: return "6E9BD8"  // calm blue
        }
    }
    var next: GoalStatus {
        switch self {
        case .onTrack: return .atRisk
        case .atRisk:  return .paused
        case .paused:  return .onTrack
        case .achieved: return .achieved
        }
    }
}

struct Goal: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var symbol: String
    var saved: Double
    var target: Double
    var monthly: Double
    var deadline: Date
    var status: GoalStatus
    var allocations: [GoalAllocation] = []   // backing assets (FD/RD, investments, bank slice, cash)
    var pct: Double { target > 0 ? min(1, saved / target) : 0 }
    var active: Bool { status == .onTrack || status == .atRisk }
    var deadlineText: String { deadline.formatted(.dateTime.month(.abbreviated).year()) }
    /// True when progress is driven by linked assets (so `saved` is derived, not manually edited).
    var assetBacked: Bool { !allocations.isEmpty }
}

// MARK: - Goal asset allocation
/// What kind of asset a `GoalAllocation` points at.
enum AllocationKind: String, Codable, CaseIterable {
    case deposit, investment, bank, cash
    var label: String {
        switch self {
        case .deposit: return "Deposit"; case .investment: return "Investment"
        case .bank: return "Bank balance"; case .cash: return "Cash"
        }
    }
    var symbol: String {
        switch self {
        case .deposit: return "lock.fill"; case .investment: return "chart.line.uptrend.xyaxis"
        case .bank: return "building.columns.fill"; case .cash: return "banknote.fill"
        }
    }
}

/// Links a portion (`percent`) of one asset to a goal. For `.cash` the contribution is the
/// manual `amount`; for the others it's the asset's live value × percent.
struct GoalAllocation: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: AllocationKind
    var assetId: UUID? = nil      // Deposit/Investment/BankAccount id; nil for cash
    var percent: Double = 100     // 0…100 — share of the asset allocated to this goal
    var amount: Double = 0        // cash: the manual amount; others: cached last-computed contribution
    var note: String = ""         // free-form label (mainly for cash)
}

// MARK: - Milestone
struct Milestone: Identifiable, Codable, Hashable {
    var id = UUID()
    var amount: Double
    var name: String
    var tag: String
    var reached: Bool
    var active: Bool
    var pct: Double           // 0...1 for active ring
}

// MARK: - Badge
struct Badge: Identifiable, Codable, Hashable {
    var id = UUID()
    var symbol: String
    var label: String
    var earned: Bool
}

// MARK: - Statement ledger
/// A record of one parsed statement (manual file, spreadsheet, or Gmail attachment). Lets the
/// user see what's been ingested and delete a statement together with all of its transactions.
struct StatementRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var fileName: String
    var source: String                 // "Imported file" / "Spreadsheet" / "Gmail"
    var importedAt: Date = Date()
    var periodStart: Date? = nil
    var periodEnd: Date? = nil
    var accountName: String? = nil
    var accountMask: String? = nil
    var txnCount: Int = 0
    var depositCount: Int = 0
    var gmailKey: String? = nil        // links to GmailManager's processed-statement ledger

    var periodText: String? {
        guard let s = periodStart, let e = periodEnd else { return nil }
        let f = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        return "\(s.formatted(f)) – \(e.formatted(f))"
    }
}

// MARK: - Data conflict (ingestion needs-review queue)
/// A field a parser couldn't resolve for an imported transaction (missing/garbled date, amount,
/// or merchant). Surfaced in Settings → Conflicts, linked back to the statement + narration.
struct DataConflict: Identifiable, Codable, Hashable {
    var id = UUID()
    var txnId: UUID? = nil
    var statementRecordId: UUID? = nil
    var field: String                  // "date" / "amount" / "merchant"
    var reason: String
    var context: String = ""           // statement file + narration snippet, for understanding
    var createdAt: Date = Date()
    var resolved: Bool = false
}

// MARK: - Currencies (for multi-currency income)
enum Currencies {
    static let common = ["INR", "USD", "EUR", "GBP", "AED", "SGD", "CAD", "AUD"]
    /// Offline fallback rates → INR (used until live FX loads).
    static let fallbackINR: [String: Double] = ["INR": 1, "USD": 83, "EUR": 90, "GBP": 105,
                                                "AED": 22.6, "SGD": 62, "CAD": 61, "AUD": 55]
    static func symbol(_ c: String) -> String {
        ["INR": "₹", "USD": "$", "EUR": "€", "GBP": "£", "AED": "AED ", "SGD": "S$", "CAD": "C$", "AUD": "A$"][c] ?? (c + " ")
    }
}

// MARK: - Income stream (manual, multi-currency)
struct IncomeStream: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String
    var annual: Double             // annual amount, in `currency`
    var currency: String = "INR"
    var monthly: Bool = false      // whether the figure was entered per-month
    var accountId: UUID? = nil     // linked bank account
    var creditDay: Int? = nil      // day of month credited (monthly salary)

    var perPeriodAmount: Double { monthly ? annual / 12 : annual }
    var periodLabel: String { monthly ? "mo" : "yr" }
}

// MARK: - Income & tax: track, regime, profile, payslip
/// Which earning situation the user is in — drives how taxable income is computed.
enum IncomeTrack: String, Codable, CaseIterable, Identifiable {
    case salaried, selfEmployed, business, mixed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .salaried: return "Salaried"
        case .selfEmployed: return "Self-employed"
        case .business: return "Business"
        case .mixed: return "Mixed"
        }
    }
    var blurb: String {
        switch self {
        case .salaried: return "Salary with TDS; import payslips"
        case .selfEmployed: return "Professional — 44ADA presumptive (50%)"
        case .business: return "Business — 44AD presumptive (6/8%)"
        case .mixed: return "Salary + profession/other income"
        }
    }
    var symbol: String {
        switch self {
        case .salaried: return "briefcase.fill"
        case .selfEmployed: return "laptopcomputer"
        case .business: return "storefront.fill"
        case .mixed: return "rectangle.3.group.fill"
        }
    }
}

enum TaxRegime: String, Codable, CaseIterable, Identifiable {
    case new, old
    var id: String { rawValue }
    var label: String { self == .new ? "New regime" : "Old regime" }
}

/// All the inputs needed to estimate India income tax. Amounts are annual ₹ for the current FY.
struct TaxProfile: Codable, Hashable {
    var track: IncomeTrack = .salaried
    var regime: TaxRegime = .new          // user's chosen/declared regime (engine still compares both)
    var autoPickRegime: Bool = true       // when true, follow whichever regime is cheaper

    // Salary (annual, taxable — i.e. gross salary; standard deduction applied by the engine)
    var grossSalary: Double = 0
    var tdsPaid: Double = 0               // TDS already deducted by employer (from payslips)

    // Presumptive
    var professionalReceipts: Double = 0  // 44ADA — gross professional receipts
    var businessTurnover: Double = 0      // 44AD — gross turnover/sales
    var businessDigitalShare: Double = 1  // 0…1 share of turnover received digitally (6% vs 8%)

    // Other taxable income (interest, rent net, capital gains treated as slab income — simplified)
    var otherIncome: Double = 0

    // Old-regime deductions (ignored under the new regime)
    var ded80C: Double = 0                // capped 1.5L
    var ded80D: Double = 0                // health insurance
    var ded80CCD1B: Double = 0            // NPS extra, capped 50k
    var dedHomeLoanInterest: Double = 0   // 24(b), capped 2L (self-occupied)
    var dedHRA: Double = 0                // exempt HRA
    var otherDeductions: Double = 0       // 80G, 80E, etc.

    // New-regime employer NPS 80CCD(2) — allowed in both regimes
    var employerNPS: Double = 0

    var advanceTaxPaid: Double = 0        // self-paid advance tax (separate from TDS)
    var seeded: Bool = false              // whether the user has set this up
}

/// A parsed/entered salary slip — drives TDS tracking, salary-component view, and annual projection.
struct Payslip: Identifiable, Codable, Hashable {
    var id = UUID()
    var employer: String = ""
    var period: Date = Date()             // the month this slip is for
    var basic: Double = 0
    var hra: Double = 0
    var allowances: Double = 0            // special + other allowances
    var grossEarnings: Double = 0
    var pf: Double = 0                    // employee PF (80C-eligible)
    var profTax: Double = 0
    var tds: Double = 0                   // income tax deducted this month
    var otherDeductions: Double = 0
    var netPay: Double = 0

    var monthLabel: String { period.formatted(.dateTime.month(.abbreviated).year()) }
}

// MARK: - Net worth composition segment
struct Segment: Identifiable, Hashable {
    var id = UUID()
    var label: String
    var value: Double
    var colorHex: String
}

// MARK: - Plan month (bar chart)
struct PlanMonth: Identifiable, Hashable {
    var id = UUID()
    var month: String
    var pct: Int              // % of budget used
    var over: Bool
}
