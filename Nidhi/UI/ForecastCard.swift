import SwiftUI
import Charts

/// "Safe to spend" headline + 30-day projected balance sparkline.
/// Lives in its own file so Home stays a layout list; the maths is in `CashflowForecast`.
struct ForecastCard: View {
    @EnvironmentObject var store: Store
    @State private var showBreakdown = false

    var body: some View {
        let f = store.forecast
        Button { showBreakdown = true } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Safe to spend").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink3)
                    Spacer()
                    Text("\(f.daysLeftInMonth) day\(f.daysLeftInMonth == 1 ? "" : "s") left")
                        .font(.caption2).foregroundStyle(Zen.ink3)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Negative is shown honestly in the calm caution tone — never clamped away.
                    Text(INR.compact(f.monthEndSurplus))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(f.monthEndSurplus < 0 ? Zen.caution : Zen.ink)
                    if f.monthEndSurplus >= 0 {
                        Text("· \(INR.compact(f.perDay))/day").font(.caption).foregroundStyle(Zen.ink3)
                    } else {
                        Text("short of plan").font(.caption).foregroundStyle(Zen.caution)
                    }
                }
                if f.points.count > 1 {
                    Chart(f.points) { p in
                        AreaMark(x: .value("Day", p.day), y: .value("Balance", p.balance))
                            .foregroundStyle(LinearGradient(colors: [Zen.accent.opacity(0.35), Zen.accent.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Day", p.day), y: .value("Balance", p.balance))
                            .foregroundStyle(Zen.accentDeep)
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 54)
                }
                Text("Projected balance over 30 days · tap for the breakdown")
                    .font(.caption2).foregroundStyle(Zen.ink3)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showBreakdown) { ForecastBreakdownSheet(forecast: f) }
    }
}

/// Line-by-line derivation of the headline. The lines are the formula, so they always add up.
struct ForecastBreakdownSheet: View {
    @Environment(\.dismiss) private var dismiss
    let forecast: CashflowForecast

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Bank balances now", forecast.startingBalance)
                } footer: {
                    Text("Liquid only — deposits and investments aren’t counted as spendable this month.")
                }

                Section("Expected income") {
                    if forecast.income.isEmpty {
                        Text("None expected before month end.").font(.caption).foregroundStyle(Zen.ink3)
                    }
                    ForEach(forecast.income) { f in
                        row(f.expectedLate ? "\(f.label) (expected)" : f.label, f.amount,
                            date: f.date)
                    }
                }

                Section {
                    if forecast.bills.isEmpty {
                        Text("No bills predicted in the next 30 days.").font(.caption).foregroundStyle(Zen.ink3)
                    }
                    ForEach(forecast.bills) { f in row(f.label, f.amount, date: f.date) }
                } header: { Text("Upcoming bills") } footer: {
                    Text("Cash leaving your account — subscriptions, SIPs and card bills. A card bill isn’t counted as new spending: those purchases already came out of your budgets when you made them.")
                }

                Section {
                    row("Budget still unspent", -forecast.remainingBudget)
                } footer: {
                    Text("What’s left of this month’s category caps, assumed to be spent evenly over the days remaining.")
                }

                Section {
                    HStack {
                        Text("Left at month end").font(.subheadline.weight(.bold))
                        Spacer()
                        Text(INR.compact(forecast.monthEndSurplus))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(forecast.monthEndSurplus < 0 ? Zen.caution : Zen.greenDeep)
                    }
                }
            }
            .zenForm()
            .navigationTitle("Safe to spend")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ label: String, _ amount: Double, date: Date? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline)
                if let date {
                    Text(date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption2).foregroundStyle(Zen.ink3)
                }
            }
            Spacer()
            Text((amount < 0 ? "−" : "") + INR.compact(abs(amount)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(amount < 0 ? Zen.ink2 : Zen.greenDeep)
        }
    }
}
