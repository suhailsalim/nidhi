import SwiftUI

struct IncomeView: View {
    @EnvironmentObject var store: Store
    @State private var showAddStream = false
    @State private var showTaxSetup = false
    @State private var showAddPayslip = false
    @State private var editingStream: IncomeStream?

    private var tax: TaxComputation { store.tax }
    private var isSalaried: Bool { store.taxProfile.track == .salaried || store.taxProfile.track == .mixed }

    var body: some View {
        VStack(spacing: 20) {
            taxHero
            if !store.taxProfile.seeded { setupPrompt }
            if store.taxProfile.seeded {
                regimeCard
                breakdownCard
                if !taxTips.isEmpty { tipsCard }
            }

            if isSalaried || !store.payslips.isEmpty { payslipsSection }

            VStack(alignment: .leading, spacing: 11) {
                SectionHeader(title: "Income streams", actionLabel: "Add") { showAddStream = true }
                if store.incomeStreams.isEmpty {
                    EmptyState(icon: "indianrupeesign.circle", title: "No income added",
                               message: "Add your salary, consulting, or other income.",
                               actionTitle: "Add income") { showAddStream = true }
                } else {
                    VStack(spacing: 9) {
                        ForEach(store.incomeStreams) { s in
                            Button { editingStream = s } label: { streamRow(s) }.buttonStyle(.plain)
                            .contextMenu {
                                Button { editingStream = s } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { store.remove(stream: s) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }

            if store.taxTotal > 0 {
                VStack(alignment: .leading, spacing: 11) {
                    SectionHeader(title: "Advance tax schedule")
                    scheduleCard
                }
            }
        }
        .navigationTitle("Income & Tax")
        .navigationSubtitle("\(store.financialYearLabel) · \(tax.selected.label)")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showTaxSetup = true } label: { Image(systemName: "slider.horizontal.3") } } }
        .task { await store.refreshFX() }
        .sheet(isPresented: $showAddStream) { AddIncomeStreamSheet() }
        .sheet(isPresented: $showTaxSetup) { TaxProfileSheet() }
        .sheet(isPresented: $showAddPayslip) { AddPayslipSheet() }
        .sheet(item: $editingStream) { AddIncomeStreamSheet(editing: $0) }
    }

    // MARK: hero
    private var taxHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ESTIMATED TAX · \(store.financialYearLabel)").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
            Text(INR.compact(store.taxTotal)).font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(Zen.ink)
            Text("\(store.taxProfile.track.label) · \(tax.selected.label) · incl. cess").font(.caption2).foregroundStyle(Zen.ink3).padding(.top, 2)
            HStack(spacing: 10) {
                miniStat("Already paid", INR.compact(tax.alreadyPaid), Zen.greenDeep, Zen.green)
                miniStat("Balance due", INR.compact(tax.balanceDue), Zen.ink2, Zen.caution)
            }.padding(.top, 16)
            ZenBar(value: store.taxTotal > 0 ? min(1, tax.alreadyPaid / store.taxTotal) : 0, tint: AnyShapeStyle(Zen.green)).padding(.top, 14)
            HStack {
                Text(store.taxTotal > 0 ? "\(Int(min(1, tax.alreadyPaid / store.taxTotal) * 100))% paid" : "Set up to estimate").font(.caption2).foregroundStyle(Zen.ink3)
                Spacer()
                Text("ITR due \(store.filingDue)").font(.caption2).foregroundStyle(Zen.ink3)
            }.padding(.top, 7)
        }
        .padding(22).zenCard(30)
    }

    private var setupPrompt: some View {
        Button { showTaxSetup = true } label: {
            HStack(spacing: 12) {
                IconChip(symbol: "sparkles", tint: Zen.accentDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up your tax profile").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                    Text("Pick your track and income to get a real slab-based estimate across both regimes").font(.caption2).foregroundStyle(Zen.ink2).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Zen.ink3)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).zenCard(tinted: Zen.accent, 20)
        }.buttonStyle(.plain)
    }

    // MARK: regime comparison
    private var regimeCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Regime comparison")
            HStack(spacing: 10) {
                regimeTile(tax.newRegime, name: "New")
                regimeTile(tax.oldRegime, name: "Old")
            }
            if tax.recommended != tax.selected, store.taxProfile.autoPickRegime == false {
                Label("Switch to the \(tax.recommended.label.lowercased()) to save \(INR.compact(tax.regimeSaving))", systemImage: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(Zen.greenDeep)
            }
        }
    }
    private func regimeTile(_ r: RegimeResult, name: String) -> some View {
        let isRec = tax.recommended == r.regime
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(name) regime").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
                if isRec { Text("BEST").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Zen.green)) }
            }
            Text(INR.compact(r.totalTax)).font(.title3.weight(.bold)).foregroundStyle(Zen.ink)
            Text("on \(INR.compact(r.taxableIncome)) taxable").font(.caption2).foregroundStyle(Zen.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).zenCard(tinted: isRec ? Zen.green : Zen.accent, 20)
    }

    // MARK: breakdown (composition + slabs)
    private var breakdownCard: some View {
        let r = tax.result
        return VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "How it's computed · \(tax.selected.label)")
            VStack(spacing: 12) {
                if tax.salaryComponent > 0 { row("Salary income", tax.salaryComponent, Zen.ink) }
                if tax.presumptiveIncome > 0 { row("Presumptive income", tax.presumptiveIncome, Zen.ink) }
                if tax.otherIncome > 0 { row("Other income", tax.otherIncome, Zen.ink) }
                row("Less: deductions", -r.deductions, Zen.greenDeep)
                Divider().overlay(Zen.track)
                row("Net taxable income", r.taxableIncome, Zen.ink, bold: true)
                Divider().overlay(Zen.track)
                ForEach(r.slabs, id: \.self) { s in
                    HStack {
                        Text("\(s.label) · \(Int(s.rate*100))%").font(.caption).foregroundStyle(Zen.ink3)
                        Spacer()
                        Text(INR.compact(s.tax)).font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
                    }
                }
                if r.rebate87A > 0 { row("Less: 87A rebate", -r.rebate87A, Zen.greenDeep) }
                if r.surcharge > 0 { row("Surcharge", r.surcharge, Zen.ink2) }
                row("Health & education cess (4%)", r.cess, Zen.ink2)
                Divider().overlay(Zen.track)
                row("Total tax", r.totalTax, Zen.ink, bold: true)
            }
            .padding(18).zenCard(26)
        }
    }

    // MARK: planning tips
    private var taxTips: [String] {
        var tips: [String] = []
        let p = store.taxProfile
        if tax.recommended != tax.selected {
            tips.append("You're on the \(tax.selected.label.lowercased()); the \(tax.recommended.label.lowercased()) is ₹\(INR.compact(tax.regimeSaving)) cheaper for you.")
        }
        // Old-regime headroom (only meaningful if old is competitive)
        if tax.recommended == .old || p.regime == .old {
            let c80 = 150_000 - min(p.ded80C, 150_000)
            if c80 > 1000 { tips.append("80C has ₹\(INR.compact(c80)) headroom — PF/ELSS/PPF/insurance can cut taxable income.") }
            if p.ded80CCD1B < 50_000 { tips.append("NPS 80CCD(1B) gives an extra ₹\(INR.compact(50_000 - p.ded80CCD1B)) deduction over 80C.") }
            if p.ded80D == 0 { tips.append("Add health-insurance premium under 80D (up to ₹25k, or ₹50k incl. parents).") }
        }
        // New-regime rebate cliff
        let nt = tax.newRegime.taxableIncome
        if nt > 1_200_000 && nt < 1_270_000 {
            tips.append("New-regime taxable is just over the ₹12L rebate line — employer NPS or reducing taxable salary could bring it under and zero the tax.")
        }
        if tax.balanceDue > 10_000 {
            tips.append("Balance of ₹\(INR.compact(tax.balanceDue)) is due — pay advance tax in instalments to avoid 234B/234C interest.")
        }
        return tips
    }
    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Tax planning")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(taxTips.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb.fill").font(.caption).foregroundStyle(Zen.accentDeep).padding(.top, 2)
                        Text(t).font(.caption).foregroundStyle(Zen.ink2)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).zenCard(22)
        }
    }

    // MARK: payslips
    private var payslipsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Payslips", actionLabel: "Add") { showAddPayslip = true }
            if store.payslips.isEmpty {
                EmptyState(icon: "doc.text.magnifyingglass", title: "No payslips",
                           message: "Import a salary slip to track TDS, components and project your annual salary.",
                           actionTitle: "Add payslip") { showAddPayslip = true }
            } else {
                VStack(spacing: 9) {
                    HStack {
                        miniStat("TDS so far", INR.compact(store.payslips.map(\.tds).reduce(0,+)), Zen.ink, Zen.accent)
                        miniStat("Projected annual", INR.compact(store.taxProfile.grossSalary), Zen.ink, Zen.green)
                    }
                    ForEach(store.payslips) { s in
                        Button { showAddPayslip = true } label: { payslipRow(s) }.buttonStyle(.plain)
                            .contextMenu { Button(role: .destructive) { store.remove(payslip: s) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
        }
    }
    private func payslipRow(_ s: Payslip) -> some View {
        HStack(spacing: 12) {
            IconChip(symbol: "doc.text.fill", size: 40, tint: Zen.accentDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.employer.isEmpty ? s.monthLabel : s.employer).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                Text("\(s.monthLabel) · TDS \(INR.compact(s.tds))").font(.caption2).foregroundStyle(Zen.ink3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(INR.compact(s.netPay > 0 ? s.netPay : s.grossEarnings)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                Text(s.netPay > 0 ? "net" : "gross").font(.caption2).foregroundStyle(Zen.ink3)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 14).zenCard(20)
    }

    // MARK: income streams
    private func streamRow(_ s: IncomeStream) -> some View {
        HStack(spacing: 12) {
            IconChip(symbol: s.symbol, size: 40, tint: Zen.greenDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                Text(subtitle(s)).font(.caption2).foregroundStyle(Zen.ink3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(INR.compact(store.inrAnnual(s))).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                if s.currency != "INR" { Text("@ ₹\(String(format: "%.1f", store.fxRate(s.currency)))").font(.caption2).foregroundStyle(Zen.ink3) }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 14).zenCard(20)
    }
    private func subtitle(_ s: IncomeStream) -> String {
        var parts: [String] = ["\(Currencies.symbol(s.currency))\(Int(s.perPeriodAmount))/\(s.periodLabel)"]
        if let acc = store.bankName(s.accountId) { parts.append(acc) }
        if let d = s.creditDay { parts.append("day \(d)") }
        return parts.joined(separator: " · ")
    }

    private func miniStat(_ t: String, _ v: String, _ c: Color, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption2.weight(.semibold)).foregroundStyle(Zen.ink2)
            Text(v).font(.title3.weight(.bold)).foregroundStyle(c)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassEffect(.regular.tint(tint.opacity(0.16)), in: .rect(cornerRadius: 16))
    }

    private func row(_ t: String, _ v: Double, _ c: Color, bold: Bool = false) -> some View {
        HStack {
            Text(t).font(.subheadline.weight(bold ? .bold : .medium)).foregroundStyle(bold ? Zen.ink : Zen.ink2)
            Spacer()
            Text((v < 0 ? "− " : "") + INR.compact(abs(v))).font(.subheadline.weight(bold ? .bold : .semibold)).foregroundStyle(c)
        }
    }

    // Advance-tax instalments — tap to mark each one paid.
    private var scheduleCard: some View {
        let labels = ["15 Jun", "15 Sep", "15 Dec", "15 Mar"]
        return VStack(spacing: 0) {
            ForEach(Array(Store.advancePcts.enumerated()), id: \.offset) { i, pct in
                let cumulative = store.taxTotal * pct
                let paid = store.advanceTaxPaidStages.contains(i)
                Button { store.toggleAdvanceStage(i) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: paid ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(paid ? Zen.green : Zen.ink3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(labels[i]).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                            Text("\(Int(pct*100))% · \(INR.compact(cumulative))").font(.caption2).foregroundStyle(Zen.ink3)
                        }
                        Spacer()
                        Text(paid ? "Paid" : "Mark paid").font(.caption.weight(.bold)).foregroundStyle(paid ? Zen.greenDeep : Zen.accentDeep)
                    }
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                if i < Store.advancePcts.count - 1 { Divider().overlay(Zen.track).padding(.leading, 36) }
            }
        }
        .padding(.horizontal, 16).zenCard(26)
    }
}
