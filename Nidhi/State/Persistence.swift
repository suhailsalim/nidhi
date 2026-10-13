import Foundation

// MARK: - Forward/backward compatible persistence
//
// RULE (do not break this): every persisted model below decodes each field with a
// fallback default via a custom `init(from:)`. This means you can freely ADD new
// stored properties to any model — old saved JSON (which lacks the new field) still
// decodes cleanly, keeping all existing data, and the new field just gets its default.
//
// When you add a NEW stored property to a persisted struct:
//   1. give it a default in the memberwise usage / seed,
//   2. add a `case` to that struct's CodingKeys,
//   3. add one `x = d.decode(.x, default: ...)` line in its init(from:).
// When you add a whole NEW collection to `Store`, add it to `Persist` the same way
// (decode(.x, default: [])). Never make decoding throw on a missing key.
//
// Custom init(from:) lives in extensions so each struct keeps its synthesized
// memberwise initializer and its synthesized `encode(to:)`.

extension KeyedDecodingContainer {
    /// Tolerant decode: missing key, null, or type mismatch all fall back to `default`.
    func decode<T: Decodable>(_ key: Key, default def: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? def
    }
}

// MARK: BudgetCategory
extension BudgetCategory {
    enum CodingKeys: String, CodingKey { case id, name, symbol, spent, plan, color, isSystem, period, customMonths, anchor, kind, capHistory }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        name = c.decode(.name, default: "")
        symbol = c.decode(.symbol, default: "circle.fill")
        spent = c.decode(.spent, default: 0)
        plan = c.decode(.plan, default: 0)
        color = c.decode(.color, default: "6E9BD8")
        isSystem = c.decode(.isSystem, default: false)
        period = BudgetPeriod(rawValue: c.decode(.period, default: "monthly")) ?? .monthly
        customMonths = c.decode(.customMonths, default: 1)
        anchor = c.decode(.anchor, default: nil)
        // Migration: pre-existing rows have no `kind` key. Default by matching name against the
        // canonical base taxonomy (so an existing "Investments" category lands on .investments,
        // not .needs) rather than hardcoding the name a second time here.
        kind = CategoryKind(rawValue: c.decode(.kind, default:
            (Store.baseCategories.first { $0.name == name }?.kind ?? .needs).rawValue)) ?? .needs
        capHistory = c.decode(.capHistory, default: [:])
    }
}

// MARK: Txn
extension Txn {
    enum CodingKeys: String, CodingKey { case id, merchant, symbol, category, account, amount, date, externalId, source, counterparty, statementId, statementRecordId, needsReview, tags, transfer, cardholder, reward, rewardCurrency, forexCurrency, forexAmount, loanId }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        merchant = c.decode(.merchant, default: "Transaction")
        symbol = c.decode(.symbol, default: "indianrupeesign.circle.fill")
        category = c.decode(.category, default: "Other")
        account = c.decode(.account, default: "")
        amount = c.decode(.amount, default: 0)
        date = c.decode(.date, default: Date())
        externalId = c.decode(.externalId, default: nil)
        source = TxnSource(rawValue: c.decode(.source, default: "unknown")) ?? .unknown
        counterparty = c.decode(.counterparty, default: nil)
        statementId = c.decode(.statementId, default: nil)
        statementRecordId = c.decode(.statementRecordId, default: nil)
        needsReview = c.decode(.needsReview, default: false)
        tags = c.decode(.tags, default: [])
        transfer = c.decode(.transfer, default: false)
        cardholder = c.decode(.cardholder, default: nil)
        reward = c.decode(.reward, default: nil)
        rewardCurrency = c.decode(.rewardCurrency, default: nil)
        forexCurrency = c.decode(.forexCurrency, default: nil)
        forexAmount = c.decode(.forexAmount, default: nil)
        loanId = c.decode(.loanId, default: nil)
    }
}

// MARK: BankAccount
extension BankAccount {
    enum CodingKeys: String, CodingKey { case id, name, logo, colorHex, type, mask, balance, bankCode, ifsc, branch, tier, imageRef, balanceAnchor, balanceAsOf }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        name = c.decode(.name, default: "")
        logo = c.decode(.logo, default: "")
        colorHex = c.decode(.colorHex, default: "4F7FC4")
        type = c.decode(.type, default: "Savings")
        mask = c.decode(.mask, default: "0000")
        balance = c.decode(.balance, default: 0)
        bankCode = c.decode(.bankCode, default: nil)
        ifsc = c.decode(.ifsc, default: nil)
        branch = c.decode(.branch, default: nil)
        tier = c.decode(.tier, default: nil)
        imageRef = c.decode(.imageRef, default: nil)
        balanceAnchor = c.decode(.balanceAnchor, default: nil)
        balanceAsOf = c.decode(.balanceAsOf, default: nil)
    }
}

// MARK: CreditCard
extension CreditCard {
    enum CodingKeys: String, CodingKey { case id, name, mask, outstanding, limit, bankCode, network, tier, colorHex, imageRef, rewardKind, rewardBalance, totalDue, minDue, dueDate, dueClearedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        name = c.decode(.name, default: "")
        mask = c.decode(.mask, default: "0000")
        outstanding = c.decode(.outstanding, default: 0)
        limit = c.decode(.limit, default: 0)
        bankCode = c.decode(.bankCode, default: nil)
        network = c.decode(.network, default: nil)
        tier = c.decode(.tier, default: nil)
        colorHex = c.decode(.colorHex, default: nil)
        imageRef = c.decode(.imageRef, default: nil)
        rewardKind = c.decode(.rewardKind, default: nil)
        rewardBalance = c.decode(.rewardBalance, default: nil)
        totalDue = c.decode(.totalDue, default: nil)
        minDue = c.decode(.minDue, default: nil)
        dueDate = c.decode(.dueDate, default: nil)
        dueClearedAt = c.decode(.dueClearedAt, default: nil)
    }
}

// MARK: Deposit
extension Deposit {
    enum CodingKeys: String, CodingKey { case id, bank, tag, rate, symbol, current, startDate, maturityDate, identifier }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        bank = c.decode(.bank, default: "")
        tag = c.decode(.tag, default: "FD")
        rate = c.decode(.rate, default: 7.0)
        symbol = c.decode(.symbol, default: "lock.fill")
        current = c.decode(.current, default: 0)
        startDate = c.decode(.startDate, default: Date())
        maturityDate = c.decode(.maturityDate, default: Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
        identifier = c.decode(.identifier, default: nil)
    }
}

// MARK: LoanAdjustment
extension LoanAdjustment {
    enum CodingKeys: String, CodingKey { case id, date, amount, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        date = c.decode(.date, default: Date())
        amount = c.decode(.amount, default: 0)
        note = c.decode(.note, default: "")
    }
}

// MARK: Loan
extension Loan {
    enum CodingKeys: String, CodingKey { case id, name, lender, principal, rate, emi, startDate, tenureMonths, mask, counterpartyKey, symbol, principalAdjustments, anchorPrincipal, anchorAsOf, closed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        name = c.decode(.name, default: "")
        lender = c.decode(.lender, default: "")
        principal = c.decode(.principal, default: 0)
        rate = c.decode(.rate, default: 0)
        emi = c.decode(.emi, default: 0)
        startDate = c.decode(.startDate, default: Date())
        tenureMonths = c.decode(.tenureMonths, default: 0)
        mask = c.decode(.mask, default: "")
        counterpartyKey = c.decode(.counterpartyKey, default: "")
        symbol = c.decode(.symbol, default: "house.fill")
        principalAdjustments = c.decode(.principalAdjustments, default: [])
        anchorPrincipal = c.decode(.anchorPrincipal, default: nil)
        anchorAsOf = c.decode(.anchorAsOf, default: nil)
        closed = c.decode(.closed, default: false)
    }
}

// MARK: InvestmentKind (unknown raw → .stock)
extension InvestmentKind {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = InvestmentKind(rawValue: raw) ?? .stock
    }
}

// MARK: Investment
extension Investment {
    enum CodingKeys: String, CodingKey { case id, name, kind, units, avgCost, identifier, lastPrice, lastUpdated }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        name = c.decode(.name, default: "")
        kind = c.decode(.kind, default: .stock)
        units = c.decode(.units, default: 0)
        avgCost = c.decode(.avgCost, default: 0)
        identifier = c.decode(.identifier, default: "")
        lastPrice = c.decode(.lastPrice, default: 0)
        lastUpdated = c.decode(.lastUpdated, default: nil)
    }
}

// MARK: GoalStatus (unknown/removed raw values fall back to .onTrack)
extension GoalStatus {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = GoalStatus(rawValue: raw) ?? .onTrack
    }
}

// MARK: Goal
extension Goal {
    enum CodingKeys: String, CodingKey { case id, title, symbol, saved, target, monthly, deadline, status, allocations }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        title = c.decode(.title, default: "")
        symbol = c.decode(.symbol, default: "star.fill")
        saved = c.decode(.saved, default: 0)
        target = c.decode(.target, default: 1)
        monthly = c.decode(.monthly, default: 0)
        deadline = c.decode(.deadline, default: Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
        status = c.decode(.status, default: .onTrack)
        allocations = c.decode(.allocations, default: [])
    }
}

// MARK: GoalAllocation
extension GoalAllocation {
    enum CodingKeys: String, CodingKey { case id, kind, assetId, percent, amount, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        kind = AllocationKind(rawValue: c.decode(.kind, default: "cash")) ?? .cash
        assetId = c.decode(.assetId, default: nil)
        percent = c.decode(.percent, default: 100)
        amount = c.decode(.amount, default: 0)
        note = c.decode(.note, default: "")
    }
}

// MARK: StatementRecord
extension StatementRecord {
    enum CodingKeys: String, CodingKey { case id, fileName, source, importedAt, periodStart, periodEnd, accountName, accountMask, txnCount, depositCount, gmailKey }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        fileName = c.decode(.fileName, default: "Statement")
        source = c.decode(.source, default: "Imported file")
        importedAt = c.decode(.importedAt, default: Date())
        periodStart = c.decode(.periodStart, default: nil)
        periodEnd = c.decode(.periodEnd, default: nil)
        accountName = c.decode(.accountName, default: nil)
        accountMask = c.decode(.accountMask, default: nil)
        txnCount = c.decode(.txnCount, default: 0)
        depositCount = c.decode(.depositCount, default: 0)
        gmailKey = c.decode(.gmailKey, default: nil)
    }
}

// MARK: DataConflict
extension DataConflict {
    enum CodingKeys: String, CodingKey { case id, txnId, statementRecordId, field, reason, context, createdAt, resolved }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        txnId = c.decode(.txnId, default: nil)
        statementRecordId = c.decode(.statementRecordId, default: nil)
        field = c.decode(.field, default: "date")
        reason = c.decode(.reason, default: "")
        context = c.decode(.context, default: "")
        createdAt = c.decode(.createdAt, default: Date())
        resolved = c.decode(.resolved, default: false)
    }
}

// MARK: IncomeStream
extension IncomeStream {
    enum CodingKeys: String, CodingKey { case id, name, symbol, annual, currency, monthly, accountId, creditDay }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        name = c.decode(.name, default: "")
        symbol = c.decode(.symbol, default: "indianrupeesign.circle")
        annual = c.decode(.annual, default: 0)
        currency = c.decode(.currency, default: "INR")
        monthly = c.decode(.monthly, default: false)
        accountId = c.decode(.accountId, default: nil)
        creditDay = c.decode(.creditDay, default: nil)
    }
}

// MARK: TaxProfile
extension TaxProfile {
    enum CodingKeys: String, CodingKey { case track, regime, autoPickRegime, grossSalary, tdsPaid, professionalReceipts, businessTurnover, businessDigitalShare, otherIncome, ded80C, ded80D, ded80CCD1B, dedHomeLoanInterest, dedHRA, otherDeductions, employerNPS, advanceTaxPaid, seeded }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = IncomeTrack(rawValue: c.decode(.track, default: "salaried")) ?? .salaried
        regime = TaxRegime(rawValue: c.decode(.regime, default: "new")) ?? .new
        autoPickRegime = c.decode(.autoPickRegime, default: true)
        grossSalary = c.decode(.grossSalary, default: 0)
        tdsPaid = c.decode(.tdsPaid, default: 0)
        professionalReceipts = c.decode(.professionalReceipts, default: 0)
        businessTurnover = c.decode(.businessTurnover, default: 0)
        businessDigitalShare = c.decode(.businessDigitalShare, default: 1)
        otherIncome = c.decode(.otherIncome, default: 0)
        ded80C = c.decode(.ded80C, default: 0)
        ded80D = c.decode(.ded80D, default: 0)
        ded80CCD1B = c.decode(.ded80CCD1B, default: 0)
        dedHomeLoanInterest = c.decode(.dedHomeLoanInterest, default: 0)
        dedHRA = c.decode(.dedHRA, default: 0)
        otherDeductions = c.decode(.otherDeductions, default: 0)
        employerNPS = c.decode(.employerNPS, default: 0)
        advanceTaxPaid = c.decode(.advanceTaxPaid, default: 0)
        seeded = c.decode(.seeded, default: false)
    }
}

// MARK: Payslip
extension Payslip {
    enum CodingKeys: String, CodingKey { case id, employer, period, basic, hra, allowances, grossEarnings, pf, profTax, tds, otherDeductions, netPay }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        employer = c.decode(.employer, default: "")
        period = c.decode(.period, default: Date())
        basic = c.decode(.basic, default: 0)
        hra = c.decode(.hra, default: 0)
        allowances = c.decode(.allowances, default: 0)
        grossEarnings = c.decode(.grossEarnings, default: 0)
        pf = c.decode(.pf, default: 0)
        profTax = c.decode(.profTax, default: 0)
        tds = c.decode(.tds, default: 0)
        otherDeductions = c.decode(.otherDeductions, default: 0)
        netPay = c.decode(.netPay, default: 0)
    }
}

// MARK: Milestone
extension Milestone {
    enum CodingKeys: String, CodingKey { case id, amount, name, tag, reached, active, pct }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        amount = c.decode(.amount, default: 0)
        name = c.decode(.name, default: "")
        tag = c.decode(.tag, default: "")
        reached = c.decode(.reached, default: false)
        active = c.decode(.active, default: false)
        pct = c.decode(.pct, default: 0)
    }
}

// MARK: Badge
extension Badge {
    enum CodingKeys: String, CodingKey { case id, symbol, label, earned }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, default: UUID())
        symbol = c.decode(.symbol, default: "star.fill")
        label = c.decode(.label, default: "")
        earned = c.decode(.earned, default: false)
    }
}
