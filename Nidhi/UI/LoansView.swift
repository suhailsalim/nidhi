import SwiftUI

// MARK: - Loans section (Wealth tab)
/// Borrowings shown as negative net worth: scheduled outstanding, principal repaid %, months left,
/// and — deliberately separate — how many EMIs we've actually seen land.
struct LoansSection: View {
    @EnvironmentObject var store: Store
    @State private var adding = false
    @State private var editing: Loan?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Loans", actionLabel: store.loans.isEmpty ? nil : "Add →") { adding = true }
            if store.loans.isEmpty {
                EmptyState(icon: "banknote", title: "No loans tracked",
                           message: "Add a home, car, personal or education loan to see net worth after what you owe.",
                           actionTitle: "Add loan") { adding = true }
            } else {
                VStack(spacing: 9) {
                    ForEach(store.loans) { l in
                        Button { editing = l } label: { LoanRow(loan: l) }.buttonStyle(.plain)
                    }
                    totalsRow
                }
            }
        }
        .sheet(isPresented: $adding) { AddLoanSheet() }
        .sheet(item: $editing) { AddLoanSheet(editing: $0) }
    }

    private var totalsRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total owed").font(.caption.weight(.semibold)).foregroundStyle(Zen.ink2)
                Text("\(INR.compact(store.monthlyEMITotal())) of EMIs a month")
                    .font(.caption2).foregroundStyle(Zen.ink3)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("−\(INR.compact(store.loansOutstanding))")
                    .font(.subheadline.weight(.bold)).foregroundStyle(Zen.caution)
                Text("\(INR.compact(store.netWorth)) net worth")
                    .font(.caption2).foregroundStyle(Zen.ink3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13).zenCard(20)
    }
}

// MARK: - One loan
struct LoanRow: View {
    @EnvironmentObject var store: Store
    var loan: Loan

    var body: some View {
        let now = Date()
        let out = loan.outstanding(asOf: now)
        let paid = loan.paidFraction(asOf: now)
        let left = loan.monthsLeft(asOf: now)
        let seen = store.emisSeen(loan)
        let scheduled = loan.scheduledPayments(asOf: now)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                IconChip(symbol: loan.symbol, size: 38, tint: Zen.caution)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(loan.displayName).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink).lineLimit(1)
                        if loan.closed {
                            Text("Closed").font(.caption2.weight(.bold)).foregroundStyle(Zen.greenDeep)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Zen.green.opacity(0.18)))
                        }
                    }
                    Text(subtitle).font(.caption2).foregroundStyle(Zen.ink3).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("−\(INR.compact(out))").font(.subheadline.weight(.bold)).foregroundStyle(Zen.caution)
                    Text("outstanding").font(.caption2).foregroundStyle(Zen.ink3)
                }
            }
            ZenBar(value: paid, tint: AnyShapeStyle(Zen.green))
            HStack(spacing: 4) {
                Text("\(Int((paid * 100).rounded()))% repaid").foregroundStyle(Zen.ink2)
                Spacer()
                Text(left > 0 ? "\(left) mo left" : "Schedule complete").foregroundStyle(Zen.ink3)
            }
            .font(.caption.weight(.semibold))

            // Scheduled vs observed. Missed/extra EMIs show up as drift rather than being
            // silently reconciled away — the schedule stays the source of truth for net worth.
            if !loan.counterpartyKey.isEmpty {
                Divider().overlay(Zen.track)
                HStack(spacing: 4) {
                    Image(systemName: "link").font(.system(size: 9, weight: .bold)).foregroundStyle(Zen.accentDeep)
                    Text("\(seen) EMI\(seen == 1 ? "" : "s") seen").foregroundStyle(Zen.ink2)
                    if seen != scheduled {
                        Text("· \(scheduled) scheduled").foregroundStyle(Zen.caution)
                    }
                    Spacer()
                    if seen != scheduled {
                        Text("−\(INR.compact(store.outstandingFromSeenEMIs(loan))) at that pace")
                            .foregroundStyle(Zen.ink3)
                    }
                }
                .font(.caption2.weight(.semibold))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .zenCard(20, interactive: true)
    }

    private var subtitle: String {
        var bits: [String] = []
        if !loan.lender.isEmpty { bits.append(loan.lender) }
        if !loan.mask.isEmpty { bits.append("••\(loan.mask)") }
        if loan.rate > 0 { bits.append(loan.rateText) }
        if loan.emi > 0 { bits.append("\(INR.compact(loan.emi))/mo") }
        bits.append(loan.tenureText)
        return bits.joined(separator: " · ")
    }
}

// MARK: - Add / edit loan
struct AddLoanSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: Loan? = nil

    @State private var name = ""
    @State private var lender = ""
    @State private var mask = ""
    @State private var symbol = "house.fill"
    @State private var principal: Double = 0
    @State private var rate: Double = 0
    @State private var emi: Double = 0
    @State private var tenureMonths: Int = 240
    @State private var start = Date()
    @State private var counterpartyKey = ""
    @State private var adjustments: [LoanAdjustment] = []
    @State private var closed = false

    @State private var recalibrate = false
    @State private var anchorPrincipal: Double = 0
    @State private var anchorAsOf = Date()

    @State private var newPrepayAmount: Double = 0
    @State private var newPrepayDate = Date()
    @State private var loaded = false

    private var suggestedEMI: Double {
        LoanMath.emi(principal: principal, annualRate: rate, months: tenureMonths)
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                termsSection
                emiLinkSection
                recalibrateSection
                prepaymentsSection
                previewSection
                if let e = editing { DeleteSheetButton(noun: "loan") { store.remove(loan: e); dismiss() } }
            }
            .zenForm()
            .navigationTitle(editing == nil ? "Add loan" : "Edit loan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { commit() }.fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: sections
    private var detailsSection: some View {
        Section("Loan") {
            LabeledField(label: "Name", placeholder: "e.g. Home loan", text: $name)
            LabeledField(label: "Lender", placeholder: "e.g. HDFC", text: $lender)
            LabeledField(label: "Account ••", placeholder: "1234", text: $mask, keyboard: .numberPad)
            Picker("Type", selection: $symbol) {
                ForEach(Loan.symbols, id: \.symbol) { s in
                    Label(s.label, systemImage: s.symbol).tag(s.symbol)
                }
            }
            Toggle("Fully repaid / closed", isOn: $closed)
        }
    }

    private var termsSection: some View {
        Section {
            LabeledAmountField(label: "Principal", amount: $principal)
            HStack {
                Text("Interest rate").foregroundStyle(Zen.ink2)
                Spacer()
                TextField("0", value: $rate, format: .number).multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad).frame(maxWidth: 80)
                Text("%").foregroundStyle(Zen.ink3)
            }
            HStack {
                Text("Tenure").foregroundStyle(Zen.ink2)
                Spacer()
                TextField("0", value: $tenureMonths, format: .number).multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad).frame(maxWidth: 80)
                Text("months").foregroundStyle(Zen.ink3)
            }
            DatePicker("Started", selection: $start, displayedComponents: .date)
            LabeledAmountField(label: "EMI", amount: $emi)
            if suggestedEMI > 0, abs(suggestedEMI - emi) > 1 {
                Button {
                    emi = (suggestedEMI * 100).rounded() / 100
                } label: {
                    Label("Use calculated EMI \(INR.full(suggestedEMI))", systemImage: "function")
                        .font(.callout)
                }
            }
        } header: { Text("Terms") } footer: {
            Text("Reducing balance. Outstanding is amortised from these terms — never from your EMI transactions, which have already left your bank balance.")
        }
    }

    private var emiLinkSection: some View {
        Section {
            let groups = store.recurringGroups
            if groups.isEmpty {
                Text("No recurring payments detected yet. You can type the EMI payee below — it's matched against each transaction's counterparty or merchant.")
                    .font(.caption).foregroundStyle(Zen.ink3)
            } else {
                Menu {
                    ForEach(groups) { g in
                        Button("\(g.name) — \(g.count)× · \(INR.compact(g.total))") {
                            counterpartyKey = g.key
                            if emi == 0, g.count > 0 { emi = (g.total / Double(g.count) * 100).rounded() / 100 }
                        }
                    }
                } label: { Label("Pick a recurring payment", systemImage: "repeat") }
            }
            LabeledField(label: "EMI payee", placeholder: "counterparty / merchant",
                         text: $counterpartyKey, autocaps: .never)
            if !counterpartyKey.isEmpty {
                HStack {
                    Text("Matching so far").foregroundStyle(Zen.ink2)
                    Spacer()
                    Text("\(matchingTxnCount) transaction\(matchingTxnCount == 1 ? "" : "s")")
                        .foregroundStyle(matchingTxnCount > 0 ? Zen.greenDeep : Zen.ink3)
                        .fontWeight(.semibold)
                }
                Button("Clear link") { counterpartyKey = "" }.foregroundStyle(Zen.caution)
            }
        } header: { Text("EMI transactions") } footer: {
            Text("Linked transactions are filed under \"\(Store.loanCategory)\" and tagged \"\(Store.loanTag)\". Deleting the loan un-links them but keeps them.")
        }
    }

    private var recalibrateSection: some View {
        Section {
            Toggle("Recalibrate outstanding", isOn: $recalibrate)
            if recalibrate {
                LabeledAmountField(label: "Outstanding", amount: $anchorPrincipal)
                DatePicker("As of", selection: $anchorAsOf, displayedComponents: .date)
            }
        } footer: {
            Text("Rate changed, or your statement disagrees? Set the balance the lender states and the date it was true — amortisation restarts from there.")
        }
    }

    private var prepaymentsSection: some View {
        Section {
            ForEach(adjustments) { a in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(INR.full(a.amount)).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                        Text(a.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(Zen.ink3)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        adjustments.removeAll { $0.id == a.id }
                    } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Zen.caution)
                }
            }
            LabeledAmountField(label: "Prepayment", amount: $newPrepayAmount)
            DatePicker("On", selection: $newPrepayDate, displayedComponents: .date)
            Button {
                guard newPrepayAmount > 0 else { return }
                adjustments.append(LoanAdjustment(date: newPrepayDate, amount: newPrepayAmount))
                newPrepayAmount = 0
            } label: { Label("Add prepayment", systemImage: "plus.circle") }
                .disabled(newPrepayAmount <= 0)
        } header: { Text("Prepayments") } footer: {
            Text("Part-payments and foreclosure amounts knock principal off the schedule on their date.")
        }
    }

    private var previewSection: some View {
        Section("Right now") {
            let preview = draft()
            let now = Date()
            LabeledReadout(label: "Outstanding", value: INR.full(preview.outstanding(asOf: now)))
            LabeledReadout(label: "Repaid", value: "\(Int((preview.paidFraction(asOf: now) * 100).rounded()))%")
            LabeledReadout(label: "Months left", value: "\(preview.monthsLeft(asOf: now))")
            if principal > 0, emi > 0, tenureMonths > 0 {
                LabeledReadout(label: "Total interest",
                               value: INR.full(LoanMath.totalInterest(principal: principal, emi: emi, months: tenureMonths)))
            }
        }
    }

    private var matchingTxnCount: Int {
        let k = Store.ruleKey(counterpartyKey)
        guard !k.isEmpty else { return 0 }
        return store.txns.filter { !$0.income && !$0.transfer && Store.ruleKey($0.counterparty ?? $0.merchant) == k }.count
    }

    // MARK: build / persist
    private func draft() -> Loan {
        Loan(id: editing?.id ?? UUID(), name: name, lender: lender, principal: principal, rate: rate,
             emi: emi, startDate: start, tenureMonths: max(0, tenureMonths), mask: mask,
             counterpartyKey: Store.ruleKey(counterpartyKey), symbol: symbol,
             principalAdjustments: adjustments,
             anchorPrincipal: recalibrate ? anchorPrincipal : nil,
             anchorAsOf: recalibrate ? anchorAsOf : nil,
             closed: closed)
    }

    private func commit() {
        let l = draft()
        if editing == nil { store.addLoan(l) } else { store.update(l) }
        dismiss()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let e = editing else { return }
        name = e.name; lender = e.lender; mask = e.mask; symbol = e.symbol
        principal = e.principal; rate = e.rate; emi = e.emi
        tenureMonths = e.tenureMonths; start = e.startDate
        counterpartyKey = e.counterpartyKey; adjustments = e.principalAdjustments; closed = e.closed
        if let ap = e.anchorPrincipal, let ad = e.anchorAsOf {
            recalibrate = true; anchorPrincipal = ap; anchorAsOf = ad
        }
    }
}

/// A read-only label/value row for a Form (the read-only twin of `LabeledField`).
struct LabeledReadout: View {
    var label: String
    var value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Zen.ink2)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(Zen.ink)
        }
    }
}
