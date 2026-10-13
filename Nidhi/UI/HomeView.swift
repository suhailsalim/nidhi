import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var gmail: GmailManager
    @State private var sheet: HomeSheet?

    enum HomeSheet: Identifiable { case settings, txns, upload, accounts, statements
        var id: Int { hashValue } }

    var body: some View {
        VStack(spacing: 22) {
            if !gmail.pending.isEmpty { pendingBanner }
            if !dueCards.isEmpty { cardDueBanner }
            if let m = MonthReviewBanner.dueMonth(store) { MonthReviewBanner(lastMonth: m) }
            hero
            statRow
            if !store.banks.isEmpty { ForecastCard() }

            let upcoming = store.upcomingCharges(within: 7)
            if !upcoming.isEmpty {
                section("Upcoming", "Insights →", { store.tab = .insights }) {
                    VStack(spacing: 9) {
                        ForEach(upcoming) { g in
                            HStack(spacing: 10) {
                                IconChip(symbol: "repeat", brandIcon: BrandCatalog.icon(for: g.name))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.name).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink).lineLimit(1)
                                    if let d = g.nextDate {
                                        Text(d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                                            .font(.caption2).foregroundStyle(Zen.ink3)
                                    }
                                }
                                Spacer()
                                Text("\(g.variableAmount ? "~" : "")\(INR.compact(g.expectedAmount))")
                                    .font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                            }
                        }
                    }
                }
            }

            section("This month's plan", "All →", { store.tab = .plan }) {
                if store.categories.isEmpty {
                    EmptyState(icon: "chart.pie", title: "No budget yet",
                               message: "Set up monthly categories to track your spending.",
                               actionTitle: "Add category") { store.tab = .plan }
                } else {
                    VStack(spacing: 9) {
                        ForEach(store.top3) { c in
                            Button { store.tab = .plan } label: { CategoryRow(c: c, compact: true) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }

            section("Accounts", "Manage →", { sheet = .accounts }) {
                if store.banks.isEmpty {
                    EmptyState(icon: "building.columns", title: "No accounts linked",
                               message: "Add an account manually, import a statement, or connect via Account Aggregator.",
                               actionTitle: "Add account") { sheet = .accounts }
                } else { accountsCarousel }
            }

            section("Recent activity", "See all →", { sheet = .txns }) {
                if store.txns.isEmpty {
                    EmptyState(icon: "list.bullet.rectangle", title: "No transactions",
                               message: "Import a bank statement (PDF) or add a transaction by hand.",
                               actionTitle: "Import statement") { sheet = .upload }
                } else { recentCard }
            }
        }
        .navigationTitle(store.userName.isEmpty ? "Good morning" : "Good morning, \(store.userName)")
        .navigationSubtitle(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.tab = .goals } label: {
                    Label("Lv \(store.level)", systemImage: "bolt.fill").labelStyle(.titleAndIcon)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { sheet = .txns } label: { Image(systemName: "magnifyingglass") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { sheet = .settings } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .settings: SettingsSheet()
            case .txns: TransactionsSheet()
            case .upload: UploadSheet()
            case .accounts: AccountsView()
            case .statements: NavigationStack { StatementsEmailView() }
            }
        }
    }

    // MARK: pending statements banner — locked PDFs (e.g. password-protected Federal/Scapia
    // statements) wait silently until unlocked; surface them so an account never goes missing.
    private var pendingBanner: some View {
        Button { sheet = .statements } label: {
            HStack(spacing: 12) {
                IconChip(symbol: "lock.doc", tint: Zen.caution)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(gmail.pending.count) statement\(gmail.pending.count == 1 ? "" : "s") need a password")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                    Text("Tap to unlock and import — your accounts won't show until then")
                        .font(.caption2).foregroundStyle(Zen.ink2).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Zen.ink3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zenCard(tinted: Zen.caution, 20)
        }.buttonStyle(.plain)
    }

    // MARK: card-due banner — any card whose bill is due within 5 days (incl. overdue) and unpaid.
    private var dueCards: [CreditCard] {
        store.cards.filter(\.needsDueAttention)
            .sorted { ($0.daysUntilDue ?? 99) < ($1.daysUntilDue ?? 99) }
    }
    private var cardDueBanner: some View {
        Button { sheet = .accounts } label: {
            HStack(spacing: 12) {
                IconChip(symbol: "creditcard.trianglebadge.exclamationmark", tint: Zen.accentDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dueBannerTitle).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                    Text(dueBannerSubtitle).font(.caption2).foregroundStyle(Zen.ink2).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Zen.ink3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .zenCard(tinted: Zen.accent, 20)
        }.buttonStyle(.plain)
    }
    private var dueBannerTitle: String {
        if dueCards.count == 1, let c = dueCards.first, let chip = c.dueChip {
            return "\(c.name) · \(chip.text.lowercased())"
        }
        return "\(dueCards.count) card bills due soon"
    }
    private var dueBannerSubtitle: String {
        if dueCards.count == 1, let c = dueCards.first, let total = c.totalDue, total > 0 {
            return "Pay \(INR.compact(total)) to avoid interest and late fees"
        }
        return "Tap to review your cards and pay before the due date"
    }

    // generic titled section
    @ViewBuilder
    private func section<C: View>(_ title: String, _ action: String?, _ act: (() -> Void)?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: title, actionLabel: action, action: act)
            content()
        }
    }

    // MARK: hero
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIQUID NET WORTH").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
            HStack(alignment: .center) {
                Text(INR.compact(store.liquidNetWorth)).font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(Zen.ink)
                Spacer()
                Button { store.tab = .wealth } label: {
                    Sparkline(points: Array(store.nwHistory.suffix(7)), tint: Zen.accent)
                        .frame(width: 66, height: 30)
                }.buttonStyle(.plain)
            }
            .padding(.top, 2)
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right")
                Text("\(INR.compact(store.nwChange)) this month")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(Zen.greenDeep)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .glassEffect(.regular.tint(Zen.green.opacity(0.18)), in: .capsule)
            .padding(.top, 8)

            // The headline stays LIQUID net worth — that's the number users know, and the milestone
            // ladder is built on it. Loans are surfaced as a labelled subtitle, never by silently
            // changing the big figure.
            if store.hasLoans {
                Button { store.tab = .wealth } label: {
                    Text("\(INR.compact(store.netWorth)) incl. loans")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink3)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }

            VStack(spacing: 7) {
                HStack {
                    Label("Road to \(store.targetLabel)", systemImage: "leaf").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
                    Spacer()
                    Text("\(store.toTargetPct)% · \(INR.compact(store.toTarget)) to go").font(.caption.weight(.bold)).foregroundStyle(Zen.ink)
                }
                ZenBar(value: Double(store.toTargetPct)/100, tint: AnyShapeStyle(Zen.calmGradient))
            }
            .padding(.top, 18)
        }
        .padding(22)
        .zenCard(tinted: Zen.accent, 30)
    }

    // MARK: stat row
    private var statRow: some View {
        HStack(spacing: 12) {
            Button { store.tab = .plan } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THIS MONTH").font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink2)
                    Text(INR.compact(store.spentTotal)).font(.title2.weight(.bold)).foregroundStyle(Zen.ink)
                    Text("of \(INR.compact(store.planTotal)) planned").font(.caption2).foregroundStyle(Zen.ink3)
                    ZenBar(value: store.planTotal > 0 ? store.spentTotal/store.planTotal : 0).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16).zenCard(22, interactive: true)
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text("ON-PLAN STREAK").font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink2)
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").foregroundStyle(Zen.green)
                    Text("\(store.streakMonths)").font(.title.weight(.bold)).foregroundStyle(Zen.ink)
                    Text("months").font(.subheadline).foregroundStyle(Zen.ink3)
                }
                Text(store.streakMonths > 0 ? "Keep it calm" : "Stay on plan to build a streak").font(.caption2).foregroundStyle(Zen.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16).zenCard(22)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var accountsCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.banks) { b in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 7) {
                            Text(b.logo).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                                .frame(width: 24, height: 24).background(Circle().fill(Color(hex: b.colorHex)))
                            Text("••\(b.mask)").font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink3)
                        }
                        Text(INR.compact(b.balance)).font(.title3.weight(.bold)).foregroundStyle(Zen.ink).padding(.top, 10)
                        Text(b.name).font(.caption2).foregroundStyle(Zen.ink3).padding(.top, 1)
                    }
                    .padding(14).frame(width: 132, alignment: .leading).zenCard(20)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var recentCard: some View {
        VStack(spacing: 0) {
            ForEach(store.recent) { t in
                HStack(spacing: 12) {
                    IconChip(symbol: t.symbol, brandIcon: BrandCatalog.icon(for: [t.merchant, t.counterparty ?? ""].joined(separator: " ")))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.merchant).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                        Text("\(t.category) · \(t.account)").font(.caption2).foregroundStyle(Zen.ink3)
                    }
                    Spacer()
                    Text((t.income ? "+" : "−") + INR.full(abs(t.amount)))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(t.income ? Zen.greenDeep : Zen.ink)
                }
                .padding(.vertical, 11)
                if t.id != store.recent.last?.id { Divider().overlay(Zen.track) }
            }
            Divider().overlay(Zen.track)
            Button { sheet = .upload } label: {
                HStack(spacing: 12) {
                    IconChip(symbol: "doc.text", tint: Zen.accentDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upload a statement").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                        Text("PDF statements · auto-categorised").font(.caption2).foregroundStyle(Zen.ink2)
                    }
                    Spacer()
                    Image(systemName: "plus.circle.fill").foregroundStyle(Zen.accentDeep)
                }
                .padding(.vertical, 12)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .zenCard(22)
    }
}

// MARK: - Category row (shared by Home + Plan)
struct CategoryRow: View {
    var c: BudgetCategory
    var compact = false
    /// When set (Plan period/month views), the row shows these figures instead of the live cap-cycle ones.
    var spentOverride: Double? = nil
    var planOverride: Double? = nil
    var periodNoun: String? = nil           // overrides the "/month" suffix label (e.g. "period")

    private var spent: Double { spentOverride ?? c.spent }
    private var plan: Double { planOverride ?? c.plan }
    private var pct: Double { plan > 0 ? spent / plan : 0 }
    private var over: Bool { spent > plan }
    private var left: Double { plan - spent }
    private var barHex: String { over ? "9AA7BE" : (pct > 0.85 ? "6E9BD8" : "7FC4A3") }

    var body: some View {
        HStack(spacing: 12) {
            IconChip(symbol: c.symbol, size: compact ? 34 : 40, tint: Color(hex: c.color))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(c.name).font(.subheadline.weight(compact ? .semibold : .bold)).foregroundStyle(Zen.ink).lineLimit(1)
                    if spentOverride == nil, c.period != .monthly {
                        Text(c.period == .custom ? "\(c.periodMonths)mo" : c.period.label)
                            .font(.caption2.weight(.bold)).foregroundStyle(Zen.accentDeep)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Zen.accent.opacity(0.16)))
                    }
                    Spacer()
                }
                ZenBar(value: pct, tint: AnyShapeStyle(Color(hex: barHex)))
                HStack(spacing: 4) {
                    Text(INR.compact(spent)).foregroundStyle(Zen.ink2)
                    Text("/ \(INR.compact(plan))").foregroundStyle(Zen.ink3)
                    if !compact {
                        Spacer()
                        Text("\(Int(pct*100))%").foregroundStyle(Color(hex: barHex)).fontWeight(.bold)
                        let noun = periodNoun ?? (c.period == .monthly ? "" : c.period.noun)
                        Text("· \(INR.compact(abs(left))) \(over ? "over" : "left")\(noun.isEmpty ? "" : "/\(noun)")").foregroundStyle(Zen.ink3)
                    }
                }.font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, compact ? 11 : 12)
        .zenCard(20, interactive: true)
    }
}
