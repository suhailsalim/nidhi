import Foundation

// MARK: - Reducing-balance amortisation (pure)
//
// Everything here is a pure static function over injected values — in particular there is **no
// `Date()` anywhere in this file**. Callers pass the "as of" moment, which makes the maths
// deterministic, unit-testable, and verifiable with a standalone `swiftc` harness (this file
// compiles on its own: it depends on nothing but Foundation).
enum LoanMath {

    /// Monthly rate from an annual reducing-balance rate:  i = rate / 1200
    /// (8.5% p.a. → 0.0070833…). Kept as a named function so every call site agrees.
    static func monthlyRate(_ annualRatePercent: Double) -> Double { annualRatePercent / 1200 }

    /// Textbook outstanding principal after `payments` level EMIs on a reducing-balance loan:
    ///
    ///     O(n) = P·(1+i)^n − E·((1+i)^n − 1) / i,        i = rate / 1200
    ///
    /// Derivation: each month the balance grows by the interest factor (1+i) and the EMI is
    /// subtracted; unrolling the recurrence O(k) = O(k-1)(1+i) − E gives the geometric series above.
    /// An interest-free loan (i == 0) degrades to the straight-line `P − E·n` — guarded because the
    /// closed form divides by i. Never returns a negative balance (an over-paid schedule reads 0).
    static func outstanding(principal: Double, annualRate: Double, emi: Double, payments: Int) -> Double {
        guard principal > 0 else { return 0 }
        let n = max(0, payments)
        let i = monthlyRate(annualRate)
        if i == 0 { return max(0, principal - emi * Double(n)) }
        let growth = pow(1 + i, Double(n))
        return max(0, principal * growth - emi * (growth - 1) / i)
    }

    /// The level EMI that clears `principal` over `months` at `annualRate` (reducing balance):
    ///
    ///     E = P·i·(1+i)^n / ((1+i)^n − 1)
    ///
    /// Used to pre-fill the EMI field when the user knows principal/rate/tenure but not the EMI.
    static func emi(principal: Double, annualRate: Double, months: Int) -> Double {
        guard principal > 0, months > 0 else { return 0 }
        let i = monthlyRate(annualRate)
        if i == 0 { return principal / Double(months) }
        let growth = pow(1 + i, Double(months))
        return principal * i * growth / (growth - 1)
    }

    /// Whole months between two instants — i.e. how many EMIs have fallen due by `to` for a
    /// schedule that started at `from` (the first EMI is due one month after the start).
    /// Returns 0 when `to` is at or before `from`.
    static func paymentsElapsed(from: Date, to: Date,
                                calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        guard to > from else { return 0 }
        return max(0, calendar.dateComponents([.month], from: from, to: to).month ?? 0)
    }

    /// Schedule-aware outstanding as of `asOf`, honouring manual principal adjustments
    /// (prepayments / part-payments / a foreclosure amount).
    ///
    /// Prepayments break the pure closed form, so the schedule is walked in segments: amortise up
    /// to each adjustment date with the closed form, knock the adjustment off the principal, then
    /// carry on from the reduced balance. Payments are capped at `tenureMonths` so a loan that has
    /// run its course reads 0 instead of amortising into the past. Pass `tenureMonths <= 0` for
    /// "no cap" (an open-ended / unknown tenure).
    static func outstanding(principal: Double, annualRate: Double, emi: Double, tenureMonths: Int,
                            start: Date, asOf: Date,
                            adjustments: [(date: Date, amount: Double)] = [],
                            calendar: Calendar = Calendar(identifier: .gregorian)) -> Double {
        guard principal > 0 else { return 0 }
        let cap = tenureMonths > 0 ? tenureMonths : Int.max
        var balance = principal
        var paid = 0
        var cursor = start

        let stops = adjustments
            .filter { $0.date > start && $0.date <= asOf && $0.amount != 0 }
            .sorted { $0.date < $1.date }
        for a in stops {
            let n = min(max(0, cap - paid), paymentsElapsed(from: cursor, to: a.date, calendar: calendar))
            balance = outstanding(principal: balance, annualRate: annualRate, emi: emi, payments: n)
            paid += n
            balance = max(0, balance - a.amount)
            cursor = a.date
            if balance == 0 { return 0 }
        }
        let n = min(max(0, cap - paid), paymentsElapsed(from: cursor, to: asOf, calendar: calendar))
        return outstanding(principal: balance, annualRate: annualRate, emi: emi, payments: n)
    }

    /// EMIs still to run as of `asOf` for a `tenureMonths` schedule that began at `start`.
    static func monthsRemaining(tenureMonths: Int, start: Date, asOf: Date,
                                calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        guard tenureMonths > 0 else { return 0 }
        return max(0, tenureMonths - min(tenureMonths, paymentsElapsed(from: start, to: asOf, calendar: calendar)))
    }

    /// Total interest paid over the full schedule (E·n − P) — 0 when the inputs don't make sense.
    static func totalInterest(principal: Double, emi: Double, months: Int) -> Double {
        max(0, emi * Double(max(0, months)) - max(0, principal))
    }
}
