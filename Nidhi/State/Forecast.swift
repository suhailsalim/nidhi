import Foundation

/// Cash-flow projection and "safe to spend".
///
/// Pure by construction: `compute` takes plain values (not `Store` models) and an injected `today`,
/// so it can be exercised offline and can't drift with the wall clock — the repo bans `Date()` inside
/// anything date-sensitive after the statement-date bug.
///
/// The formula, which the breakdown sheet renders line by line and which MUST add up exactly:
///
///     month-end surplus = starting liquid balance
///                       + income expected before month end
///                       − bills expected before month end   (cash outflows: subscriptions, SIPs, card dues)
///                       − budget still unspent this month   (discretionary spend yet to happen)
///
/// Cash and spend are deliberately two different ledgers. A credit-card bill is a *cash* outflow but
/// not new *spend* — the purchases behind it were already counted against category budgets when they
/// happened — so a card due reduces the projected balance and never appears as budget outflow.
struct CashflowForecast {
    struct Flow: Identifiable, Equatable {
        var id: String { "\(label)-\(date.timeIntervalSince1970)" }
        var label: String
        var date: Date
        /// Positive = money in, negative = money out.
        var amount: Double
        /// An income stream whose credit day has passed with no matching income txn — projected anyway.
        var expectedLate: Bool = false
    }

    struct Point: Identifiable, Equatable {
        var id: Int { day }
        var day: Int
        var date: Date
        var balance: Double
    }

    struct Inputs {
        /// Liquid only — bank balances. Deposits and investments are not spendable this month.
        var startingBalance: Double = 0
        var income: [Flow] = []
        /// Subscriptions, recurring transfers/SIPs and card dues, all as cash outflows.
        var bills: [Flow] = []
        /// Σ max(0, monthlyPlan − spent) across non-investment categories.
        var remainingBudget: Double = 0
    }

    var startingBalance: Double
    var income: [Flow]
    var bills: [Flow]
    var remainingBudget: Double
    /// Projected balance per day over the horizon, for the sparkline.
    var points: [Point]
    /// Honest, and negative when you're short — never clamped.
    var monthEndSurplus: Double
    /// Surplus spread over the days left in the month. Clamped at 0: "spend −₹140/day" is nonsense.
    var perDay: Double
    var daysLeftInMonth: Int

    static func compute(_ i: Inputs, today: Date, horizon: Int = 30,
                        calendar: Calendar = .current) -> CashflowForecast {
        let cal = calendar
        let start = cal.startOfDay(for: today)
        let monthEnd = cal.dateInterval(of: .month, for: start).map {
            cal.date(byAdding: .day, value: -1, to: $0.end) ?? start
        } ?? start
        let daysLeft = max(1, (cal.dateComponents([.day], from: start, to: cal.startOfDay(for: monthEnd)).day ?? 0) + 1)

        // Only flows landing on/before month end feed the surplus, so the breakdown the user reads
        // sums exactly to the headline. Later flows still bend the 30-day sparkline.
        let inMonth: (Flow) -> Bool = { cal.startOfDay(for: $0.date) <= cal.startOfDay(for: monthEnd) }
        let incomeInMonth = i.income.filter(inMonth).map(\.amount).reduce(0, +)
        let billsInMonth = i.bills.filter(inMonth).map { abs($0.amount) }.reduce(0, +)
        let surplus = i.startingBalance + incomeInMonth - billsInMonth - i.remainingBudget

        // Discretionary budget is assumed to be spent evenly across the days left in the month.
        let burnPerDay = daysLeft > 0 ? i.remainingBudget / Double(daysLeft) : 0
        var balance = i.startingBalance
        var points: [Point] = []
        for d in 0..<max(1, horizon) {
            guard let date = cal.date(byAdding: .day, value: d, to: start) else { break }
            let sameDay: (Flow) -> Bool = { cal.isDate($0.date, inSameDayAs: date) }
            balance += i.income.filter(sameDay).map(\.amount).reduce(0, +)
            balance -= i.bills.filter(sameDay).map { abs($0.amount) }.reduce(0, +)
            if cal.startOfDay(for: date) <= cal.startOfDay(for: monthEnd) { balance -= burnPerDay }
            points.append(Point(day: d, date: date, balance: balance))
        }

        return CashflowForecast(
            startingBalance: i.startingBalance, income: i.income, bills: i.bills,
            remainingBudget: i.remainingBudget, points: points,
            monthEndSurplus: surplus, perDay: max(0, surplus / Double(daysLeft)),
            daysLeftInMonth: daysLeft)
    }

    /// The breakdown must reconcile to the headline; callers can assert this rather than trusting the UI.
    var breakdownReconciles: Bool {
        let cal = Calendar.current
        guard let last = points.last?.date else { return false }
        let monthEnd = cal.dateInterval(of: .month, for: points.first?.date ?? last).map {
            cal.date(byAdding: .day, value: -1, to: $0.end) ?? last
        } ?? last
        let inc = income.filter { cal.startOfDay(for: $0.date) <= cal.startOfDay(for: monthEnd) }
            .map(\.amount).reduce(0, +)
        let out = bills.filter { cal.startOfDay(for: $0.date) <= cal.startOfDay(for: monthEnd) }
            .map { abs($0.amount) }.reduce(0, +)
        return abs((startingBalance + inc - out - remainingBudget) - monthEndSurplus) < 0.01
    }
}
