import Foundation

// MARK: - Loans (liabilities) — Store surface
//
// DO NOT "FIX" THIS INTO A TXN SUM. A loan's outstanding is computed from its *amortisation
// schedule* (`LoanMath`), never from the sum of its EMI transactions. Those debits already left
// the bank balance, so:
//
//     netWorth = (banks, already net of the EMIs paid) − (amortised outstanding)
//
// Adding the EMI txns into the loan as well would subtract the same rupee twice.
//
// The gap between the schedule and reality (missed / extra EMIs) is surfaced deliberately as
// "scheduled" vs "based on N EMIs seen" rather than silently reconciled.
extension Store {
    /// The base category EMI debits are filed under. Already exists in `baseCategories` — link to
    /// it, never create a duplicate.
    static let loanCategory = "EMI & Loans"
    static let loanTag = "EMI"

    // MARK: derived totals
    var openLoans: [Loan] { loans.filter { !$0.closed } }
    var hasLoans: Bool { !openLoans.isEmpty }

    /// Scheduled outstanding for one loan right now. The pure maths takes an injected date; this is
    /// the single place the app's "now" enters loan figures.
    func outstanding(_ l: Loan) -> Double { l.outstanding(asOf: Date()) }

    /// Total borrowed principal still outstanding across all open loans.
    var loansOutstanding: Double {
        let now = Date()
        return openLoans.reduce(0) { $0 + $1.outstanding(asOf: now) }
    }

    /// Liquid net worth minus borrowings. `liquidNetWorth` and the milestone ladder deliberately
    /// stay as they were — their semantics predate loans, and silently moving them would move every
    /// user's milestones. Wealth shows both figures side by side; Home labels the difference.
    var netWorth: Double { liquidNetWorth - loansOutstanding }
    /// Everything tracked, net of both card outstandings and loans.
    var totalTrackedNetOfLoans: Double { totalTracked - loansOutstanding }

    func monthlyEMITotal() -> Double { openLoans.reduce(0) { $0 + $1.emi } }

    // MARK: mutations
    func addLoan(_ l: Loan) { loans.append(l); recomputeSpent(); save() }
    func update(_ l: Loan) {
        guard let i = loans.firstIndex(where: { $0.id == l.id }) else { return }
        loans[i] = l
        recomputeSpent()   // re-links EMI txns (the counterparty may have changed) and re-totals
        save()
    }
    /// Deleting a loan un-links its transactions but **keeps** them — that money really did leave
    /// the account. `applyLoanLinks` (via `recomputeSpent`) drops the stale `loanId` + "EMI" tag.
    func remove(loan: Loan) {
        loans.removeAll { $0.id == loan.id }
        recomputeSpent(); save()
    }
    func addAdjustment(_ a: LoanAdjustment, to loan: Loan) {
        guard let i = loans.firstIndex(where: { $0.id == loan.id }) else { return }
        loans[i].principalAdjustments.append(a); save()
    }
    func removeAdjustment(_ id: UUID, from loan: Loan) {
        guard let i = loans.firstIndex(where: { $0.id == loan.id }) else { return }
        loans[i].principalAdjustments.removeAll { $0.id == id }; save()
    }
    /// Recalibrate a floating-rate loan: adopt a stated outstanding as the new anchor principal
    /// as of a date, mirroring the bank balance-anchor pattern.
    func recalibrate(_ loan: Loan, outstanding: Double, asOf: Date) {
        guard let i = loans.firstIndex(where: { $0.id == loan.id }) else { return }
        loans[i].anchorPrincipal = outstanding
        loans[i].anchorAsOf = asOf
        save()
    }

    // MARK: EMI linking
    /// Tag every transaction whose counterparty matches a loan's `counterpartyKey`: category
    /// "EMI & Loans", an "EMI" facet tag, and the loan's id. Runs from `recomputeSpent()` so it
    /// covers *existing* transactions as well as every ingestion path (Gmail, statements, manual).
    /// Idempotent, and it un-links transactions whose loan has been deleted or re-pointed.
    func applyLoanLinks() {
        var byKey: [String: UUID] = [:]
        for l in loans where !l.counterpartyKey.isEmpty {
            byKey[Self.ruleKey(l.counterpartyKey)] = l.id
        }
        let symbol = categories.first { $0.name == Self.loanCategory }?.symbol
            ?? Self.symbolFor(Self.loanCategory)

        for i in txns.indices {
            let t = txns[i]
            // Only real debits are EMIs. Income/transfers can't service a loan.
            let key = (t.income || t.transfer) ? "" : Self.ruleKey(t.counterparty ?? t.merchant)
            guard let id = byKey[key], !key.isEmpty else {
                if t.loanId != nil {                       // the loan went away — un-link, keep the txn
                    txns[i].loanId = nil
                    txns[i].tags.removeAll { $0 == Self.loanTag }
                }
                continue
            }
            if txns[i].loanId != id { txns[i].loanId = id }
            if txns[i].category != Self.loanCategory {
                txns[i].category = Self.loanCategory
                txns[i].symbol = symbol
            }
            if !txns[i].tags.contains(Self.loanTag) { txns[i].tags.append(Self.loanTag) }
        }
    }

    /// Transactions linked to a loan, newest first.
    func emiTxns(_ l: Loan) -> [Txn] { txns.filter { $0.loanId == l.id }.sorted { $0.date > $1.date } }
    /// How many EMIs we have actually seen land for this loan.
    func emisSeen(_ l: Loan) -> Int { txns.filter { $0.loanId == l.id }.count }
    /// Total rupees seen paid toward this loan (EMIs include interest — this is not principal).
    func emiPaid(_ l: Loan) -> Double { txns.filter { $0.loanId == l.id }.reduce(0) { $0 + abs($1.amount) } }
    /// Outstanding implied by the EMIs actually observed, ignoring the calendar. Compared against
    /// the scheduled figure this makes missed / extra payments visible as drift instead of hiding
    /// them — see `LoansSection`.
    func outstandingFromSeenEMIs(_ l: Loan) -> Double {
        LoanMath.outstanding(principal: l.schedulePrincipal, annualRate: l.rate, emi: l.emi,
                             payments: emisSeen(l))
    }
    /// A loan's linked recurring group, when the key still matches one.
    func recurringGroup(forKey key: String) -> RecurringGroup? {
        let k = Self.ruleKey(key)
        return k.isEmpty ? nil : recurringGroups.first { $0.key == k }
    }
}
