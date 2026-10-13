import Foundation

// MARK: - India income-tax estimator (FY 2025-26 / AY 2026-27)
//
// Indicative only — NOT tax advice. Slabs/rebates are the individual (age < 60) figures for
// FY 2025-26. Surcharge marginal relief is approximated. Verify with a CA / the ITR utility.

/// One slab's contribution, for the slab-wise breakdown UI.
struct TaxSlab: Hashable {
    var lower: Double
    var upper: Double?       // nil = no upper bound
    var rate: Double         // 0…1
    var taxed: Double        // income falling in this slab
    var tax: Double          // taxed * rate
    var label: String {
        let u = upper.map { INR.compact($0) } ?? "+"
        return "\(INR.compact(lower)) – \(u)"
    }
}

/// Full result for one regime.
struct RegimeResult: Hashable {
    var regime: TaxRegime
    var grossTotalIncome: Double     // before deductions
    var deductions: Double           // total deductions applied (incl. standard deduction)
    var taxableIncome: Double        // rounded net taxable
    var slabs: [TaxSlab]
    var baseTax: Double              // sum of slabs
    var rebate87A: Double            // section 87A rebate
    var surcharge: Double
    var cess: Double                 // 4% health & education cess
    var totalTax: Double             // baseTax - rebate + surcharge + cess (≥0)
}

/// Both regimes + which to use, plus the inputs used.
struct TaxComputation: Hashable {
    var salaryComponent: Double      // taxable salary (after standard deduction is handled per regime)
    var presumptiveIncome: Double    // 44ADA + 44AD presumptive profit
    var otherIncome: Double
    var newRegime: RegimeResult
    var oldRegime: RegimeResult
    var recommended: TaxRegime       // cheaper one
    var selected: TaxRegime          // what the user is actually on
    var alreadyPaid: Double          // TDS + advance tax

    var result: RegimeResult { selected == .new ? newRegime : oldRegime }
    var totalTax: Double { result.totalTax }
    var balanceDue: Double { max(0, totalTax - alreadyPaid) }
    /// What switching to the recommended regime would save vs the selected one.
    var regimeSaving: Double { max(0, result.totalTax - (recommended == .new ? newRegime : oldRegime).totalTax) }
}

enum TaxEngine {
    // Health & education cess.
    static let cessRate = 0.04
    static let salaryStdDeductionNew = 75_000.0
    static let salaryStdDeductionOld = 50_000.0

    // FY 2025-26 new-regime slabs (115BAC).
    static let newSlabs: [(Double, Double?, Double)] = [
        (0, 400_000, 0.0), (400_000, 800_000, 0.05), (800_000, 1_200_000, 0.10),
        (1_200_000, 1_600_000, 0.15), (1_600_000, 2_000_000, 0.20),
        (2_000_000, 2_400_000, 0.25), (2_400_000, nil, 0.30),
    ]
    // FY 2025-26 old-regime slabs (individual < 60).
    static let oldSlabs: [(Double, Double?, Double)] = [
        (0, 250_000, 0.0), (250_000, 500_000, 0.05),
        (500_000, 1_000_000, 0.20), (1_000_000, nil, 0.30),
    ]

    /// Presumptive professional profit under 44ADA (50% of receipts).
    static func presumptive44ADA(_ receipts: Double) -> Double { receipts * 0.5 }
    /// Presumptive business profit under 44AD: 6% of digital turnover + 8% of the rest.
    static func presumptive44AD(turnover: Double, digitalShare: Double) -> Double {
        let d = max(0, min(1, digitalShare))
        return turnover * d * 0.06 + turnover * (1 - d) * 0.08
    }

    static func compute(_ p: TaxProfile, fyStreamsSalary: Double = 0) -> TaxComputation {
        // Income components (track-aware).
        var salary = 0.0, presumptive = 0.0
        switch p.track {
        case .salaried:
            salary = p.grossSalary
        case .selfEmployed:
            presumptive = presumptive44ADA(p.professionalReceipts)
        case .business:
            presumptive = presumptive44AD(turnover: p.businessTurnover, digitalShare: p.businessDigitalShare)
        case .mixed:
            salary = p.grossSalary
            presumptive = presumptive44ADA(p.professionalReceipts)
                        + presumptive44AD(turnover: p.businessTurnover, digitalShare: p.businessDigitalShare)
        }
        let other = p.otherIncome

        let newR = regime(.new, salary: salary, presumptive: presumptive, other: other, profile: p)
        let oldR = regime(.old, salary: salary, presumptive: presumptive, other: other, profile: p)
        let recommended: TaxRegime = newR.totalTax <= oldR.totalTax ? .new : .old
        let selected = p.autoPickRegime ? recommended : p.regime

        return TaxComputation(salaryComponent: salary, presumptiveIncome: presumptive, otherIncome: other,
                              newRegime: newR, oldRegime: oldR, recommended: recommended, selected: selected,
                              alreadyPaid: p.tdsPaid + p.advanceTaxPaid)
    }

    private static func regime(_ r: TaxRegime, salary: Double, presumptive: Double, other: Double, profile p: TaxProfile) -> RegimeResult {
        let stdDeduction = salary > 0 ? (r == .new ? salaryStdDeductionNew : salaryStdDeductionOld) : 0
        let gross = salary + presumptive + other

        // Deductions.
        var deductions = stdDeduction + p.employerNPS    // 80CCD(2) allowed in both
        if r == .old {
            deductions += min(p.ded80C, 150_000)
            deductions += p.ded80D
            deductions += min(p.ded80CCD1B, 50_000)
            deductions += min(p.dedHomeLoanInterest, 200_000)
            deductions += p.dedHRA
            deductions += p.otherDeductions
        }
        let taxable = max(0, (gross - deductions).rounded())

        let slabsDef = r == .new ? newSlabs : oldSlabs
        var slabs: [TaxSlab] = []
        var baseTax = 0.0
        for (lo, hi, rate) in slabsDef {
            let top = hi ?? taxable
            guard taxable > lo else { continue }
            let amt = min(taxable, top) - lo
            if amt <= 0 { continue }
            let tax = amt * rate
            baseTax += tax
            slabs.append(TaxSlab(lower: lo, upper: hi, rate: rate, taxed: amt, tax: tax))
        }

        let rebate = rebate87A(regime: r, taxable: taxable, baseTax: baseTax)
        let afterRebate = max(0, baseTax - rebate)
        let surcharge = surchargeAmount(regime: r, taxable: taxable, tax: afterRebate)
        let cess = (afterRebate + surcharge) * cessRate
        let total = (afterRebate + surcharge + cess).rounded()

        return RegimeResult(regime: r, grossTotalIncome: gross, deductions: deductions, taxableIncome: taxable,
                            slabs: slabs, baseTax: baseTax, rebate87A: rebate, surcharge: surcharge, cess: cess, totalTax: total)
    }

    /// Section 87A. New regime FY25-26: full rebate if taxable ≤ 12L (rebate capped at the tax, with
    /// marginal relief just above 12L). Old regime: full rebate if taxable ≤ 5L (cap 12,500).
    private static func rebate87A(regime r: TaxRegime, taxable: Double, baseTax: Double) -> Double {
        if r == .new {
            if taxable <= 1_200_000 { return baseTax }
            // marginal relief: tax can't exceed income above the 12L threshold
            let excess = taxable - 1_200_000
            if baseTax > excess { return max(0, baseTax - excess) }
            return 0
        } else {
            if taxable <= 500_000 { return min(baseTax, 12_500) }
            return 0
        }
    }

    /// Surcharge on tax for high incomes (approx; new regime caps at 25%).
    private static func surchargeAmount(regime r: TaxRegime, taxable: Double, tax: Double) -> Double {
        let rate: Double
        switch taxable {
        case ..<5_000_000: rate = 0
        case ..<10_000_000: rate = 0.10
        case ..<20_000_000: rate = 0.15
        case ..<50_000_000: rate = 0.25
        default: rate = r == .new ? 0.25 : 0.37
        }
        return tax * rate
    }
}
