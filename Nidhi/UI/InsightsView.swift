import SwiftUI
import Charts

/// Brand & tag spending analytics (excludes transfers / card-bill payments).
struct InsightsView: View {
    @EnvironmentObject var store: Store
    @State private var months = 1
    @State private var trendTag: String? = nil

    private let donutColors = ["6E9BD8", "7FC4A3", "5BA585", "4F7FC4", "9AA7BE", "B8902E", "8C7FC4"]

    var body: some View {
        ZStack {
            ZenBackground()
            ScrollView {
                VStack(spacing: 20) {
                    periodChips
                    MonthReportEntryCard()
                    AIInsightsCard()
                    tagCard
                    subscriptionsCard
                    intlRewardsCard
                    brandCard
                    trendCard
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
            }
        }
        .navigationTitle("Insights")
    }

    private var periodChips: some View {
        HStack(spacing: 8) {
            ForEach([(1, "This month"), (3, "3 months"), (6, "6 months")], id: \.0) { m, label in
                Button { months = m } label: {
                    Text(label).font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(months == m ? Zen.accentDeep : Zen.track.opacity(0.5), in: Capsule())
                        .foregroundStyle(months == m ? .white : Zen.ink2)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: spend by tag (donut + legend)
    private var tagCard: some View {
        let all = store.spendByTag(months: months)
        let top = Array(all.prefix(6))
        let rest = all.dropFirst(6).map(\.amount).reduce(0, +)
        let segs = top + (rest > 0 ? [(tag: "Other", amount: rest)] : [])
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Spending by tag")
            if segs.isEmpty {
                Text("No spending in this period.").font(.caption).foregroundStyle(Zen.ink3)
            } else {
                HStack(spacing: 18) {
                    Chart(Array(segs.enumerated()), id: \.offset) { i, s in
                        SectorMark(angle: .value("v", s.amount), innerRadius: .ratio(0.62), angularInset: 2)
                            .cornerRadius(4)
                            .foregroundStyle(Color(hex: donutColors[i % donutColors.count]))
                    }
                    .frame(width: 110, height: 110)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                            HStack(spacing: 9) {
                                Circle().fill(Color(hex: donutColors[i % donutColors.count])).frame(width: 9, height: 9)
                                Text(s.tag).font(.caption.weight(.medium)).foregroundStyle(Zen.ink).lineLimit(1)
                                Spacer()
                                Text(INR.compact(s.amount)).font(.caption.weight(.bold)).foregroundStyle(Zen.ink)
                            }
                        }
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }

    // MARK: international spend + card rewards
    private var intlRewardsCard: some View {
        let intl = store.internationalSpend(months: months)
        let rewards = store.rewardsEarned(months: months)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "International & rewards")
            if intl.count == 0 && rewards.isEmpty {
                Text("No international spend or card rewards in this period.").font(.caption).foregroundStyle(Zen.ink3)
            } else {
                if intl.count > 0 {
                    HStack {
                        Label("International spend", systemImage: "globe").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                        Spacer()
                        Text(INR.compact(intl.total)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                    }
                    if !intl.byCurrency.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(intl.byCurrency, id: \.currency) { c in
                                    Text("\(c.currency) · \(INR.compact(c.amount))").font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Capsule().fill(Zen.accent.opacity(0.14))).foregroundStyle(Zen.accentDeep)
                                }
                            }
                        }
                    }
                    Text("\(intl.count) transaction\(intl.count == 1 ? "" : "s") abroad").font(.caption2).foregroundStyle(Zen.ink3)
                }
                if !rewards.isEmpty {
                    if intl.count > 0 { Divider().opacity(0.4) }
                    ForEach(rewards, id: \.currency) { r in
                        HStack {
                            Label(r.currency, systemImage: "star.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.greenDeep)
                            Spacer()
                            Text("+\(NumberFormatter.localizedString(from: NSNumber(value: r.total), number: .decimal))")
                                .font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                        }
                    }
                    Text("Rewards earned this period").font(.caption2).foregroundStyle(Zen.ink3)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }

    // MARK: subscriptions & recurring bills
    /// Fixed subscriptions and variable recurring bills are totalled separately — an electricity
    /// autopay has a real cadence but no fixed price, so folding it into "subscription burn" would
    /// overstate a figure people treat as cancellable.
    private var subscriptionsCard: some View {
        let groups = store.recurringGroups.filter { $0.cadence != nil }
        let burn = store.subscriptionBurn
        let bills = store.recurringBillsBurn
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Subscriptions & recurring")
            if groups.isEmpty {
                Text("Nothing recurring detected yet — this needs at least three charges to the same payee.")
                    .font(.caption).foregroundStyle(Zen.ink3)
            } else {
                HStack {
                    Label("Subscriptions", systemImage: "repeat").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                    Spacer()
                    Text("\(INR.compact(burn))/mo").font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                }
                if bills > 0 {
                    HStack {
                        Label("Recurring bills (variable)", systemImage: "bolt").font(.caption).foregroundStyle(Zen.ink2)
                        Spacer()
                        Text("~\(INR.compact(bills))/mo").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
                    }
                }
                Divider().opacity(0.4)
                ForEach(groups) { g in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(.subheadline.weight(.semibold))
                                .foregroundStyle(g.muted ? Zen.ink3 : Zen.ink).lineLimit(1)
                            Text(subtitle(for: g)).font(.caption2).foregroundStyle(Zen.ink3)
                        }
                        Spacer()
                        Text("\(g.variableAmount ? "~" : "")\(INR.compact(g.expectedAmount))")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(g.muted ? Zen.ink3 : Zen.ink)
                        Button { store.toggleRecurringMute(g.key) } label: {
                            Image(systemName: g.muted ? "bell.slash.fill" : "bell")
                                .font(.caption).foregroundStyle(g.muted ? Zen.caution : Zen.accentDeep)
                        }.buttonStyle(.plain)
                    }
                    .opacity(g.muted ? 0.6 : 1)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }

    private func subtitle(for g: Store.RecurringGroup) -> String {
        guard let cad = g.cadence else { return "\(g.count) charges" }
        if g.possiblyCancelled { return "\(cad.label) · possibly cancelled" }
        if g.muted { return "\(cad.label) · muted" }
        guard let next = g.nextDate else { return cad.label }
        return "\(cad.label) · next \(next.formatted(.dateTime.day().month(.abbreviated)))"
    }

    // MARK: top brands (horizontal bars)
    private var brandCard: some View {
        let brands = Array(store.spendByBrand(months: months).prefix(8))
        let maxV = brands.map(\.amount).max() ?? 1
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Top brands")
            if brands.isEmpty {
                Text("No spending in this period.").font(.caption).foregroundStyle(Zen.ink3)
            } else {
                ForEach(Array(brands.enumerated()), id: \.offset) { _, b in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            IconChip(symbol: "circle.grid.2x2", brandIcon: BrandCatalog.icon(forBrand: b.brand), size: 26)
                            Text(b.brand).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink).lineLimit(1)
                            Spacer()
                            Text(INR.compact(b.amount)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                        }
                        ZenBar(value: maxV > 0 ? b.amount / maxV : 0, tint: AnyShapeStyle(Zen.accent))
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }

    // MARK: tag trend (6-month sparkline)
    private var trendCard: some View {
        let tags = store.spendByTag(months: 6).map(\.tag).filter { $0 != "Untagged" }
        let selected = trendTag ?? tags.first
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Tag trend")
            if let sel = selected {
                Menu {
                    ForEach(tags, id: \.self) { t in Button(t) { trendTag = t } }
                } label: {
                    HStack { TagPill(text: sel); Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Zen.ink3); Spacer() }
                }
                let pts = store.monthlyTagSpend(sel, months: 6)
                Sparkline(points: pts, tint: TagStyle.color(sel), filled: true, showDot: true)
                    .frame(height: 64)
                HStack {
                    Text("6-month total").font(.caption2).foregroundStyle(Zen.ink3)
                    Spacer()
                    Text(INR.compact(pts.reduce(0, +))).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                }
            } else {
                Text("Tag a few transactions to see trends.").font(.caption).foregroundStyle(Zen.ink3)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).zenCard(26)
    }
}
