import SwiftUI
import Charts

/// The window the Plan screen reports over. Monthly is the default; the rest let the user review how a
/// whole year (or year-to-date) went. Monthly navigation steps months; the others step years.
enum PlanPeriodMode: String, CaseIterable, Identifiable {
    case monthly = "Monthly", ytd = "YTD", fytd = "FYTD", calendarYear = "Year", financialYear = "FY"
    var id: String { rawValue }
    var full: String {
        switch self {
        case .monthly: return "Monthly"
        case .ytd: return "Year to date"
        case .fytd: return "Financial year to date"
        case .calendarYear: return "Full calendar year"
        case .financialYear: return "Financial year (Apr–Mar)"
        }
    }
}

/// A resolved reporting window: [start, end), how many months of budget it represents, and a title.
struct PlanWindow {
    var start: Date
    var end: Date
    var months: Int            // months of cap to compare actuals against (elapsed for to-date modes)
    var title: String
    var canGoForward: Bool     // false at the present period
}

struct PlanView: View {
    @EnvironmentObject var store: Store
    @State private var sheet: PlanSheet?
    @State private var mode: PlanPeriodMode = .monthly
    @State private var offset = 0              // 0 = current; +1 = one period back (months if monthly, else years)

    /// Single sheet route for the screen — replaces three separate `@State` bools/optionals that
    /// used to back three stacked `.sheet` modifiers (unreliable when more than one could be active
    /// at once; this is also what caused the "view transactions" filter to sometimes show the wrong
    /// sheet/content).
    enum PlanSheet: Identifiable {
        case add, edit(BudgetCategory), drill(String)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let c): return "edit-\(c.id)"
            case .drill(let name): return "drill-\(name)"
            }
        }
    }

    private var window: PlanWindow { Self.window(mode: mode, offset: offset) }
    private func spent(_ c: BudgetCategory) -> Double { store.spend(inCategory: c.name, from: window.start, to: window.end) }
    /// The window's months as "YYYY-MM" keys. Always exactly `window.months` entries, so a category
    /// with no recorded history sums to `monthlyPlan * months` — identical to the pre-snapshot behaviour.
    private var windowMonthKeys: [String] {
        let cal = Calendar.current
        let first = cal.dateInterval(of: .month, for: window.start)?.start ?? window.start
        return (0..<max(0, window.months)).compactMap { i in
            cal.date(byAdding: .month, value: i, to: first).map { Store.monthKey($0) }
        }
    }
    /// Past months use the cap that was in force then; the current month always reads the live cap so
    /// an in-month edit reflects immediately (never via its own snapshot, which could be stale).
    private func plan(_ c: BudgetCategory) -> Double {
        let live = Store.monthKey(Date())
        return windowMonthKeys.map { $0 == live ? c.monthlyPlan : c.plan(forMonth: $0) }.reduce(0, +)
    }
    private var periodSpent: Double { store.totalSpend(from: window.start, to: window.end) }
    private var periodPlan: Double { store.categories.filter { $0.kind != .investments }.map { plan($0) }.reduce(0, +) }
    private var periodLeft: Double { periodPlan - periodSpent }
    private var periodPct: Int { periodPlan > 0 ? Int((periodSpent / periodPlan * 100).rounded()) : 0 }
    private var periodIncome: Double { store.totalIncome(from: window.start, to: window.end) }

    var body: some View {
        VStack(spacing: 20) {
            periodNav
            hero
            if periodIncome > 0 || !store.incomeStreams.isEmpty { incomeSummary }
            if store.txns.contains(where: { !$0.income }) {
                VStack(alignment: .leading, spacing: 11) {
                    SectionHeader(title: "Plan vs actual")
                    barChart
                }
            }
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader(title: "Categories")
                if store.categories.isEmpty {
                    EmptyState(icon: "chart.pie", title: "No budget categories",
                               message: "Add categories to plan your monthly spend.",
                               actionTitle: "Add category") { sheet = .add }
                } else {
                    VStack(spacing: 9) {
                        ForEach(store.categories) { c in categoryRow(c) }
                    }
                }
            }
        }
        .navigationTitle("Plan")
        .navigationSubtitle(window.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Period", selection: $mode) {
                        ForEach(PlanPeriodMode.allCases) { m in Text(m.full).tag(m) }
                    }
                    Divider()
                    Button { sheet = .add } label: { Label("Add category", systemImage: "plus") }
                    Button {
                        if BudgetLiveActivity.isRunning { BudgetLiveActivity.stop() }
                        else { BudgetLiveActivity.start(month: store.currentMonthName, spent: store.spentTotal, plan: store.planTotal, daysLeft: store.daysLeftInMonth) }
                    } label: {
                        Label(BudgetLiveActivity.isRunning ? "Stop Live Activity" : "Track live", systemImage: BudgetLiveActivity.isRunning ? "stop.circle" : "bolt.badge.clock")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onChange(of: mode) { _, _ in offset = 0 }
        .sheet(item: $sheet) { s in
            switch s {
            case .add: AddCategorySheet()
            case .edit(let c): AddCategorySheet(editing: c)
            case .drill(let name): TransactionsSheet(category: name)
            }
        }
    }

    // MARK: period navigation (‹ June 2026 ›)
    private var periodNav: some View {
        HStack {
            Button { offset += 1 } label: { navChevron("chevron.left") }
            Spacer()
            VStack(spacing: 1) {
                Text(window.title).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                Text(mode.full).font(.caption2).foregroundStyle(Zen.ink3)
            }
            Spacer()
            Button { if window.canGoForward { offset -= 1 } } label: { navChevron("chevron.right") }
                .disabled(!window.canGoForward).opacity(window.canGoForward ? 1 : 0.35)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).zenCard(20)
    }
    private func navChevron(_ s: String) -> some View {
        Image(systemName: s).font(.subheadline.weight(.bold)).foregroundStyle(Zen.accentDeep)
            .frame(width: 34, height: 34).background(Circle().fill(Zen.accent.opacity(0.14)))
    }

    private var hero: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SPENT").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
                    Text(INR.compact(periodSpent)).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Zen.ink)
                    Text("of \(INR.compact(periodPlan)) planned").font(.caption).foregroundStyle(Zen.ink3)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(INR.compact(abs(periodLeft))).font(.subheadline.weight(.bold)).foregroundStyle(periodLeft < 0 ? Zen.caution : Zen.greenDeep)
                    Text(periodLeft < 0 ? "over budget" : "left to spend").font(.caption2).foregroundStyle(Zen.ink3)
                }
            }
            ZenBar(value: periodPlan > 0 ? periodSpent / periodPlan : 0, tint: AnyShapeStyle(Zen.calmGradient)).padding(.top, 14)
            Text(heroCaption).font(.caption2).foregroundStyle(Zen.ink3).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7)
        }
        .padding(20).zenCard(28)
    }
    private var heroCaption: String {
        if mode == .monthly && offset == 0 {
            return "\(periodPct)% of budget used · \(store.daysLeftInMonth) days left in \(store.currentMonthName)"
        }
        return "\(periodPct)% of budget used · \(window.months) month\(window.months == 1 ? "" : "s") · \(window.title)"
    }

    // MARK: income summary — real credited income for the period, links to the Income tab
    private var incomeSummary: some View {
        Button { store.tab = .income } label: {
            HStack(spacing: 10) {
                IconChip(symbol: "indianrupeesign.circle.fill", size: 34, tint: Zen.greenDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Income").font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink2)
                    Text(periodIncome > 0 ? "\(INR.compact(periodIncome)) credited" : "Not credited yet")
                        .font(.subheadline.weight(.bold)).foregroundStyle(periodIncome > 0 ? Zen.ink : Zen.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Zen.ink3)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).zenCard(18, interactive: true)
        }.buttonStyle(.plain)
    }

    private var barChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(store.planMonths) { m in
                BarMark(x: .value("Month", m.month),
                        y: .value("Used", m.pct),
                        width: .fixed(22))
                    .foregroundStyle(m.over ? Zen.caution : Zen.accent)
                    .cornerRadius(6)
                    .annotation(position: .top) {
                        Text("\(m.pct)%").font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink3)
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
            .frame(height: 130)

            HStack(spacing: 16) {
                legend(Zen.accent, "On plan")
                legend(Zen.caution, "Over budget")
            }
        }
        .padding(18).zenCard(26)
    }

    @ViewBuilder private func categoryRow(_ c: BudgetCategory) -> some View {
        HStack(spacing: 8) {
            Button { sheet = .drill(c.name) } label: {
                CategoryRow(c: c, spentOverride: spent(c), planOverride: plan(c),
                            periodNoun: mode == .monthly ? nil : "period")
            }.buttonStyle(.plain)
            Button { sheet = .edit(c) } label: {
                Image(systemName: "pencil").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.accentDeep)
                    .frame(width: 36, height: 36).background(Circle().fill(Zen.accent.opacity(0.14)))
            }.buttonStyle(.plain).accessibilityLabel("Edit \(c.name)")
        }
        .contextMenu {
            Button { sheet = .edit(c) } label: { Label("Edit", systemImage: "pencil") }
            Button { sheet = .drill(c.name) } label: { Label("View transactions", systemImage: "list.bullet") }
            Button(role: .destructive) { store.remove(category: c) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10)
            Text(t).font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
        }
    }

    // MARK: window resolution
    static func window(mode: PlanPeriodMode, offset: Int) -> PlanWindow {
        let cal = Calendar.current, now = Date()
        func endOfToday() -> Date { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now }
        switch mode {
        case .monthly:
            let base = cal.date(byAdding: .month, value: -offset, to: now) ?? now
            let start = cal.dateInterval(of: .month, for: base)?.start ?? base
            let end = cal.date(byAdding: .month, value: 1, to: start) ?? base
            return PlanWindow(start: start, end: end, months: 1,
                              title: start.formatted(.dateTime.month(.wide).year()), canGoForward: offset > 0)
        case .ytd:
            let year = cal.component(.year, from: now) - offset
            let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
            let isCurrent = offset == 0
            let end = isCurrent ? endOfToday() : (cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? now)
            let months = isCurrent ? cal.component(.month, from: now) : 12
            return PlanWindow(start: start, end: end, months: months, title: "\(year) · year to date", canGoForward: offset > 0)
        case .fytd:
            let start = cal.date(byAdding: .year, value: -offset, to: Store.financialYearStart(now)) ?? now
            let isCurrent = offset == 0
            let fullEnd = cal.date(byAdding: .year, value: 1, to: start) ?? now
            let end = isCurrent ? endOfToday() : fullEnd
            let months = isCurrent ? max(1, (cal.dateComponents([.month], from: start, to: now).month ?? 0) + 1) : 12
            let sy = cal.component(.year, from: start) % 100
            return PlanWindow(start: start, end: end, months: months, title: "FY \(sy)–\(sy + 1) · to date", canGoForward: offset > 0)
        case .calendarYear:
            let year = cal.component(.year, from: now) - offset
            let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
            let end = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? now
            return PlanWindow(start: start, end: end, months: 12, title: "\(year)", canGoForward: offset > 0)
        case .financialYear:
            let start = cal.date(byAdding: .year, value: -offset, to: Store.financialYearStart(now)) ?? now
            let end = cal.date(byAdding: .year, value: 1, to: start) ?? now
            let sy = cal.component(.year, from: start) % 100
            return PlanWindow(start: start, end: end, months: 12, title: "FY \(sy)–\(sy + 1)", canGoForward: offset > 0)
        }
    }
}
