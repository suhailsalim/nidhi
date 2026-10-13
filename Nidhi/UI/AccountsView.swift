import SwiftUI

struct AccountsView: View {
    var embedded = false   // true when pushed from Settings (no Done button; uses the nav back)
    @EnvironmentObject var store: Store
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var gmail: GmailManager
    @Environment(\.dismiss) private var dismiss
    @State private var showDeposit = false
    @State private var showConnect = false
    @State private var showBank = false
    @State private var showCard = false
    @State private var showInvestment = false
    @State private var showPending = false
    @State private var editingBank: BankAccount?
    @State private var editingCard: CreditCard?
    @State private var editingDeposit: Deposit?
    @State private var editingInvestment: Investment?
    @State private var allocateTarget: AllocTarget?
    @State private var refreshing = false
    @State private var drill: AcctDrill?

    /// Drill into one account's transactions.
    struct AcctDrill: Identifiable { let id = UUID(); let name: String }

    private var aaEnabled: Bool { store.accountAggregatorEnabled }

    /// One asset to quick-allocate to a goal.
    struct AllocTarget: Identifiable {
        let id = UUID()
        let kind: AllocationKind
        let assetId: UUID
        let name: String
        let value: Double
    }

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    @ViewBuilder private var content: some View {
            ZStack {
                ZenBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        if !gmail.pending.isEmpty { pendingBanner }
                        if aaEnabled, case .idle = sync.phase {} else if aaEnabled {
                            HStack { SyncStatus(phase: sync.phase); Spacer() }
                        }
                        banksGroup
                        cardsGroup
                        investmentsGroup
                        depositsGroup
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showBank = true } label: { Label("Add bank account", systemImage: "building.columns") }
                        Button { showCard = true } label: { Label("Add credit card", systemImage: "creditcard") }
                        Button { showInvestment = true } label: { Label("Add investment", systemImage: "chart.line.uptrend.xyaxis") }
                        Button { showDeposit = true } label: { Label("Add deposit", systemImage: "lock") }
                        if !store.investments.isEmpty {
                            Divider()
                            Button { refresh() } label: { Label("Refresh prices", systemImage: "arrow.clockwise") }.disabled(refreshing)
                        }
                        if aaEnabled {
                            Divider()
                            Button { sync.sync(into: store) } label: { Label("Sync via Account Aggregator", systemImage: "arrow.triangle.2.circlepath") }.disabled(sync.isWorking)
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showDeposit) { AddDepositSheet() }
            .sheet(isPresented: $showConnect) { ConnectBankSheet() }
            .sheet(isPresented: $showBank) { AddBankSheet() }
            .sheet(isPresented: $showCard) { AddCardSheet() }
            .sheet(isPresented: $showInvestment) { AddInvestmentSheet() }
            .sheet(item: $editingBank) { AddBankSheet(editing: $0) }
            .sheet(item: $editingCard) { AddCardSheet(editing: $0) }
            .sheet(item: $editingDeposit) { AddDepositSheet(editing: $0) }
            .sheet(item: $editingInvestment) { AddInvestmentSheet(editing: $0) }
            .sheet(item: $allocateTarget) { t in
                QuickAllocateSheet(kind: t.kind, assetId: t.assetId, assetName: t.name, assetValue: t.value)
            }
            .sheet(item: $drill) { d in TransactionsSheet(account: d.name) }
            .sheet(isPresented: $showPending) { NavigationStack { StatementsEmailView() } }
    }

    private func refresh() { refreshing = true; Task { await store.refreshQuotes(); refreshing = false } }

    // MARK: pending statements banner — same purpose as HomeView's, so a locked statement can't be
    // missed here either (mirrors HomeView.pendingBanner, reuses the same StatementsEmailView).
    private var pendingBanner: some View {
        Button { showPending = true } label: {
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

    /// Circular "view transactions" button shown next to each account.
    private func drillButton(_ name: String) -> some View {
        Button { drill = .init(name: name) } label: {
            Image(systemName: "list.bullet").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.accentDeep)
                .frame(width: 42, height: 42).background(Circle().fill(Zen.accent.opacity(0.14)))
        }
        .buttonStyle(.plain).accessibilityLabel("View \(name) transactions")
    }

    @ViewBuilder private var banksGroup: some View {
        group("Bank accounts", INR.compact(store.banksTotal), Zen.ink) {
            VStack(spacing: 9) {
                if store.banks.isEmpty {
                    EmptyState(icon: "building.columns", title: "No accounts",
                               message: "Add manually\(aaEnabled ? " or connect via Account Aggregator" : "").",
                               actionTitle: "Add account") { showBank = true }
                }
                ForEach(store.banks) { b in
                    HStack(spacing: 8) {
                        Button { editingBank = b } label: { bankRow(b) }.buttonStyle(.plain)
                        drillButton(b.name)
                    }
                    .contextMenu {
                        Button { editingBank = b } label: { Label("Edit", systemImage: "pencil") }
                        Button { drill = .init(name: b.name) } label: { Label("View transactions", systemImage: "list.bullet") }
                        Button { allocateTarget = .init(kind: .bank, assetId: b.id, name: b.name, value: b.balance) } label: { Label("Allocate to goal", systemImage: "link.badge.plus") }
                        Button(role: .destructive) { store.remove(bank: b) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                if aaEnabled { Button { showConnect = true } label: { linkRow }.buttonStyle(.plain) }
            }
        }
    }

    @ViewBuilder private var cardsGroup: some View {
        group("Credit cards", store.cards.isEmpty ? "" : "\(INR.compact(store.cardsTotal)) due", Zen.ink2) {
            VStack(spacing: 9) {
                if store.cards.isEmpty {
                    EmptyState(icon: "creditcard", title: "No cards",
                               message: "Track outstanding balances and utilisation.",
                               actionTitle: "Add card") { showCard = true }
                }
                ForEach(store.cards) { c in
                    VStack(spacing: 8) {
                        Button { editingCard = c } label: { cardRow(c) }.buttonStyle(.plain)
                        Button { drill = .init(name: c.name) } label: {
                            Label("View transactions", systemImage: "list.bullet")
                                .font(.caption.weight(.semibold)).foregroundStyle(Zen.accentDeep)
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(Capsule().fill(Zen.accent.opacity(0.12)))
                        }.buttonStyle(.plain)
                    }
                    .contextMenu {
                        Button { editingCard = c } label: { Label("Edit", systemImage: "pencil") }
                        Button { drill = .init(name: c.name) } label: { Label("View transactions", systemImage: "list.bullet") }
                        Button(role: .destructive) { store.remove(card: c) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
    }

    @ViewBuilder private var investmentsGroup: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Investments · Stocks & funds").font(.headline).foregroundStyle(Zen.ink)
                Spacer()
                if !store.investments.isEmpty {
                    Text(INR.compact(store.investmentsTotal)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                }
            }
            if store.investments.isEmpty {
                EmptyState(icon: "chart.line.uptrend.xyaxis", title: "No investments",
                           message: "Add stocks (NSE) or mutual funds (AMFI code). NAV updates live.",
                           actionTitle: "Add investment") { showInvestment = true }
            } else {
                VStack(spacing: 9) {
                    ForEach(store.investments) { i in
                        Button { editingInvestment = i } label: { investmentRow(i) }.buttonStyle(.plain)
                            .contextMenu {
                                Button { editingInvestment = i } label: { Label("Edit", systemImage: "pencil") }
                                Button { allocateTarget = .init(kind: .investment, assetId: i.id, name: i.name, value: i.currentValue) } label: { Label("Allocate to goal", systemImage: "link.badge.plus") }
                                Button(role: .destructive) { store.remove(investment: i) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                    if refreshing { ProgressView().tint(Zen.accentDeep) }
                }
            }
        }
    }

    @ViewBuilder private var depositsGroup: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Deposits · FD & RD").font(.headline).foregroundStyle(Zen.ink)
                Spacer()
                Button { showDeposit = true } label: { Label("Add", systemImage: "plus") }.font(.subheadline.weight(.semibold))
            }
            if store.deposits.isEmpty {
                EmptyState(icon: "lock", title: "No deposits",
                           message: "Add fixed or recurring deposits to track maturity.",
                           actionTitle: "Add deposit") { showDeposit = true }
            } else {
                VStack(spacing: 9) {
                    ForEach(store.deposits) { d in
                        Button { editingDeposit = d } label: { depositRow(d) }.buttonStyle(.plain)
                            .contextMenu {
                                Button { editingDeposit = d } label: { Label("Edit", systemImage: "pencil") }
                                Button { allocateTarget = .init(kind: .deposit, assetId: d.id, name: "\(d.bank) \(d.tag)", value: d.current) } label: { Label("Allocate to goal", systemImage: "link.badge.plus") }
                                Button(role: .destructive) { store.remove(deposit: d) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func group<C: View>(_ t: String, _ v: String, _ c: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(t).font(.headline).foregroundStyle(Zen.ink)
                Spacer()
                Text(v).font(.subheadline.weight(.bold)).foregroundStyle(c)
            }
            content()
        }
    }

    private func bankRow(_ b: BankAccount) -> some View {
        HStack(spacing: 12) {
            BankBadge(monogram: b.logo, colorHex: b.colorHex, imageRef: b.imageRef, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.name).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                Text(bankSubtitle(b)).font(.caption2).foregroundStyle(Zen.ink3).lineLimit(1)
            }
            Spacer()
            Text(INR.compact(b.balance)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
        }
        .padding(.horizontal, 15).padding(.vertical, 14).zenCard(20, interactive: true)
    }
    private func bankSubtitle(_ b: BankAccount) -> String {
        var bits = [b.type, "••\(b.mask)"]
        if let t = b.tier, !t.isEmpty { bits.insert(t, at: 1) }
        if let br = b.branch, !br.isEmpty { bits.append(br) }
        return bits.joined(separator: " · ")
    }

    private var linkRow: some View {
        HStack(spacing: 12) {
            IconChip(symbol: "link", size: 34, tint: Zen.accentDeep)
            VStack(alignment: .leading, spacing: 1) {
                Text("Link a bank account").font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                Text("Securely via Account Aggregator").font(.caption2).foregroundStyle(Zen.ink3)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink3)
        }
        .padding(.horizontal, 15).padding(.vertical, 13).zenCard(18, interactive: true)
    }

    private func cardRow(_ c: CreditCard) -> some View {
        VStack(spacing: 8) {
            CardCoverView(card: c, bankName: BankCatalog.info(c.bankCode)?.name ?? c.name)
            if let chip = c.dueChip {
                HStack(spacing: 6) {
                    Image(systemName: chip.text == "Paid" ? "checkmark.circle.fill" : "calendar.badge.clock")
                        .font(.caption2)
                    Text(dueChipText(c, chip.text)).font(.caption2.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(chip.text == "Paid" ? Zen.greenDeep : (chip.overdue ? Zen.caution : Zen.ink3))
            }
            ZenBar(value: Double(c.util)/100, tint: AnyShapeStyle(Color(hex: c.utilColorHex)))
        }
    }

    private func dueChipText(_ c: CreditCard, _ base: String) -> String {
        guard base != "Paid", let total = c.totalDue, total > 0 else { return base }
        return "\(base) · \(INR.compact(total))"
    }

    private func investmentRow(_ i: Investment) -> some View {
        let gain = i.pnl >= 0
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconChip(symbol: i.kind.symbol, size: 40, tint: Zen.greenDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text(i.name).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                    Text("\(i.kind.label) · \(formatUnits(i.units)) @ \(INR.compact(i.lastPrice > 0 ? i.lastPrice : i.avgCost))")
                        .font(.caption2).foregroundStyle(Zen.ink3)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(INR.compact(i.currentValue)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                    Text("\(gain ? "▲" : "▼") \(INR.compact(abs(i.pnl))) (\(String(format: "%.1f", abs(i.pnlPct)))%)")
                        .font(.caption2.weight(.semibold)).foregroundStyle(gain ? Zen.greenDeep : Zen.caution)
                }
            }
        }
        .padding(15).zenCard(20)
    }

    private func formatUnits(_ u: Double) -> String { u == u.rounded() ? String(Int(u)) : String(format: "%.2f", u) }

    private func depositRow(_ d: Deposit) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconChip(symbol: d.symbol, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("\(d.bank) \(d.tag)").font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                        Text(d.rateText).font(.caption2.weight(.bold)).foregroundStyle(Zen.ink3)
                            .padding(.horizontal, 7).padding(.vertical, 1).glassEffect(.regular, in: .capsule)
                    }
                    Text(d.sub).font(.caption2).foregroundStyle(Zen.ink3)
                }
                Spacer()
                Text(INR.compact(d.current)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
            }
            ZenBar(value: d.progress, tint: AnyShapeStyle(Zen.calmGradient)).padding(.top, 12)
            HStack {
                Text("Matures \(d.maturesText)").font(.caption2).foregroundStyle(Zen.ink3)
                Spacer()
                Text("\(Int(d.progress*100))% of term").font(.caption2).foregroundStyle(Zen.ink3)
            }.padding(.top, 7)
        }
        .padding(15).zenCard(20)
    }
}
