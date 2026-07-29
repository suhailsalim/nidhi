import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Show a Form/List over the zen background.
    func zenForm() -> some View { self.scrollContentBackground(.hidden).background(ZenBackground()) }
}

// File documents for export
struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(_ d: Data) { data = d }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
/// Carries `Data`, not `String` — the CSV ships a UTF-8 BOM and re-encoding through a String
/// would strip it, which is exactly what makes ₹ mojibake in Excel.
struct CSVFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    var data: Data
    init(_ d: Data) { data = d }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
}

// Reusable horizontal icon picker
private struct IconPicker: View {
    let symbols: [String]
    @Binding var selection: String
    var tint: Color = Zen.accentDeep
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(symbols, id: \.self) { s in
                    IconChip(symbol: s, size: 44, tint: selection == s ? .white : tint)
                        .background(selection == s ? tint : .clear, in: .rect(cornerRadius: 14))
                        .onTapGesture { selection = s }
                }
            }.padding(.vertical, 4)
        }.listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}

// MARK: - Transactions (filter, sort, running balance)
enum TxnSort: String, CaseIterable { case newest = "Newest", oldest = "Oldest", amountHigh = "Amount ↓", amountLow = "Amount ↑" }
enum TxnType: String, CaseIterable { case all = "All", spend = "Spend", income = "Income" }
enum DatePreset: String, CaseIterable { case all = "All", thisMonth = "This month", last7 = "7 days", last30 = "30 days", custom = "Custom" }

struct TransactionsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false
    @State private var editing: Txn?
    @State private var showFilters = false
    // filters
    @State private var account: String? = nil          // bank or card name
    @State private var category: String? = nil
    @State private var type: TxnType = .all
    @State private var sort: TxnSort = .newest
    @State private var preset: DatePreset = .all
    @State private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var toDate = Date()
    @State private var tag: String? = nil
    @State private var hideTransfers = false
    @State private var exportCSV = false
    @State private var exportJSON = false
    @State private var query = ""

    /// Default presentation, or pre-filtered for a drill-in (a category, account, or tag).
    init(account: String? = nil, category: String? = nil, tag: String? = nil) {
        _account = State(initialValue: account)
        _category = State(initialValue: category)
        _tag = State(initialValue: tag)
    }

    private var activeCount: Int {
        (account != nil ? 1 : 0) + (category != nil ? 1 : 0) + (type != .all ? 1 : 0) + (preset != .all ? 1 : 0)
            + (sort != .newest ? 1 : 0) + (tag != nil ? 1 : 0) + (hideTransfers ? 1 : 0)
    }
    private var allTags: [String] { Array(Set(store.txns.flatMap(\.tags))).sorted() }

    private var dateBounds: (Date, Date)? {
        let cal = Calendar.current, now = Date()
        switch preset {
        case .all: return nil
        case .thisMonth: return (cal.dateInterval(of: .month, for: now)?.start ?? now, now)
        case .last7: return (cal.date(byAdding: .day, value: -7, to: now) ?? now, now)
        case .last30: return (cal.date(byAdding: .day, value: -30, to: now) ?? now, now)
        case .custom: return (cal.startOfDay(for: fromDate), cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate)) ?? toDate)
        }
    }

    private var filtered: [Txn] {
        var xs = store.txns
        // Search narrows *within* whatever preset the drill-in supplied, so it composes with it
        // rather than replacing it.
        let words = Store.searchWords(query)
        if !words.isEmpty { xs = xs.filter { store.txnMatches($0, words: words) } }
        if let a = account { xs = xs.filter { $0.account == a } }
        if let c = category { xs = xs.filter { $0.category == c } }
        if let tg = tag { xs = xs.filter { $0.tags.contains(tg) } }
        if hideTransfers { xs = xs.filter { !$0.transfer } }
        if type == .spend { xs = xs.filter { !$0.income } } else if type == .income { xs = xs.filter { $0.income } }
        if let (f, t) = dateBounds { xs = xs.filter { $0.date >= f && $0.date <= t } }
        switch sort {
        case .newest: xs.sort { $0.date > $1.date }
        case .oldest: xs.sort { $0.date < $1.date }
        case .amountHigh: xs.sort { abs($0.amount) > abs($1.amount) }
        case .amountLow: xs.sort { abs($0.amount) < abs($1.amount) }
        }
        return xs
    }

    /// Reconstructs the running bank balance / card outstanding right after each txn of the
    /// selected account, by reversing later transactions from the current figure.
    private var running: [UUID: (value: Double, isCard: Bool, limit: Double)] {
        guard let a = account else { return [:] }
        let chrono = store.txns.filter { $0.account == a }.sorted { $0.date < $1.date }
        var map: [UUID: (Double, Bool, Double)] = [:]
        if let bank = store.banks.first(where: { $0.name == a }) {
            var bal = bank.balance
            for t in chrono.reversed() { map[t.id] = (bal, false, 0); bal -= t.amount }
        } else if let card = store.cards.first(where: { $0.name == a }) {
            var out = card.outstanding
            for t in chrono.reversed() { map[t.id] = (out, true, card.limit); out += t.amount }
        }
        return map
    }

    var body: some View {
        NavigationStack {
            List {
                quickChips
                let rows = filtered
                if rows.isEmpty {
                    Text(store.txns.isEmpty ? "No transactions yet. Add one, or import a statement." : "No transactions match these filters.")
                        .font(.caption).foregroundStyle(Zen.ink3).listRowBackground(Color.clear)
                }
                let run = running
                ForEach(rows) { t in
                    Button { editing = t } label: { row(t, run[t.id]) }
                        .buttonStyle(.plain).listRowBackground(Color.clear)
                        .swipeActions { Button(role: .destructive) { store.remove(txn: t) } label: { Label("Delete", systemImage: "trash") } }
                }
            }
            .zenForm()
            .navigationTitle("Transactions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: activeCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Exports exactly what's on screen — the active filters, in the chosen sort order.
                    Menu {
                        Button { exportCSV = true } label: { Label("Export as CSV", systemImage: "tablecells") }
                        Button { exportJSON = true } label: { Label("Export as JSON", systemImage: "curlybraces") }
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button { showLog = true } label: { Image(systemName: "plus") } }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Merchant, payee, tag or amount")
            .fileExporter(isPresented: $exportCSV, document: CSVFile(TxnExporter.csv(filtered)),
                          contentType: .commaSeparatedText,
                          defaultFilename: "WinTheMoney-transactions-\(stamp())") { _ in }
            .fileExporter(isPresented: $exportJSON, document: BackupFile(TxnExporter.json(filtered)),
                          contentType: .json,
                          defaultFilename: "WinTheMoney-transactions-\(stamp())") { _ in }
            .sheet(isPresented: $showLog) { LogTxnSheet() }
            .sheet(item: $editing) { LogTxnSheet(editing: $0) }
            .sheet(isPresented: $showFilters) {
                TxnFilterSheet(account: $account, category: $category, type: $type, sort: $sort,
                               preset: $preset, fromDate: $fromDate, toDate: $toDate,
                               tag: $tag, hideTransfers: $hideTransfers, allTags: allTags)
            }
        }
    }

    @ViewBuilder private func row(_ t: Txn, _ run: (value: Double, isCard: Bool, limit: Double)?) -> some View {
        HStack(spacing: 12) {
            IconChip(symbol: t.symbol, brandIcon: BrandCatalog.icon(for: [t.merchant, t.counterparty ?? ""].joined(separator: " ")))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if t.needsReview {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(Color(hex: "9AA7BE"))
                    }
                    Text(t.merchant).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                }
                Text("\(t.category) · \(t.account) · \(t.date.formatted(.dateTime.day().month()))"
                     + (t.cardholder.map { " · \($0)’s add-on card" } ?? ""))
                    .font(.caption2).foregroundStyle(Zen.ink3).lineLimit(1)
                let pills = t.tags.filter { $0 != "International" }   // shown via the globe chip instead
                if !pills.isEmpty || t.transfer {
                    HStack(spacing: 4) {
                        if t.transfer { TagPill(text: "Credit card bill") }
                        ForEach(pills.prefix(t.transfer ? 1 : 2), id: \.self) { TagPill(text: $0) }
                    }
                }
                if t.isInternational || t.rewardLabel != nil {
                    HStack(spacing: 8) {
                        if let fx = t.forexLabel {
                            Label(fx, systemImage: "globe").font(.caption2.weight(.semibold)).foregroundStyle(Zen.accentDeep)
                        } else if t.isInternational {
                            Label("International", systemImage: "globe").font(.caption2.weight(.semibold)).foregroundStyle(Zen.accentDeep)
                        }
                        if let rl = t.rewardLabel {
                            Label(rl, systemImage: "star.fill").font(.caption2.weight(.semibold)).foregroundStyle(Zen.greenDeep)
                        }
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((t.income ? "+" : "−") + INR.full(abs(t.amount)))
                    .font(.subheadline.weight(.bold)).foregroundStyle(t.income ? Zen.greenDeep : Zen.ink)
                if let r = run {
                    Text(r.isCard ? "used \(INR.compact(r.value))" : "bal \(INR.compact(r.value))")
                        .font(.caption2).foregroundStyle(Zen.ink3)
                }
            }
        }
    }

    private var quickChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DatePreset.allCases.filter { $0 != .custom }, id: \.self) { p in
                    chip(p.rawValue, on: preset == p) { preset = (preset == p ? .all : p) }
                }
                if activeCount > 0 { chip("Clear", on: false, tint: Zen.ink) { clearFilters() } }
            }.padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
        .listRowBackground(Color.clear)
    }
    private func chip(_ text: String, on: Bool, tint: Color = Zen.accentDeep, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(text).font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? tint : Zen.track.opacity(0.5), in: Capsule())
                .foregroundStyle(on ? .white : Zen.ink2)
        }.buttonStyle(.plain)
    }
    private func clearFilters() { account = nil; category = nil; type = .all; sort = .newest; preset = .all; tag = nil; hideTransfers = false }
}

// MARK: - Transactions filter sheet
struct TxnFilterSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Binding var account: String?
    @Binding var category: String?
    @Binding var type: TxnType
    @Binding var sort: TxnSort
    @Binding var preset: DatePreset
    @Binding var fromDate: Date
    @Binding var toDate: Date
    @Binding var tag: String?
    @Binding var hideTransfers: Bool
    var allTags: [String]
    private var categoryFilterOptions: [String] {
        var seen = Set<String>()
        return (store.categories.map(\.name) + ["Income"]).filter { seen.insert($0).inserted }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Picker("Bank or card", selection: $account) {
                        Text("All").tag(String?.none)
                        ForEach(store.accountNames, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        Text("All").tag(String?.none)
                        ForEach(categoryFilterOptions, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                if !allTags.isEmpty {
                    Section("Tag") {
                        Picker("Tag", selection: $tag) {
                            Text("All").tag(String?.none)
                            ForEach(allTags, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                }
                Section("Show") {
                    Picker("Type", selection: $type) { ForEach(TxnType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    Picker("Sort by", selection: $sort) { ForEach(TxnSort.allCases, id: \.self) { Text(label($0)).tag($0) } }
                    Toggle("Hide transfers & card bills", isOn: $hideTransfers)
                }
                Section("Period") {
                    Picker("Range", selection: $preset) { ForEach(DatePreset.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    if preset == .custom {
                        DatePicker("From", selection: $fromDate, displayedComponents: .date)
                        DatePicker("To", selection: $toDate, displayedComponents: .date)
                    }
                }
            }
            .zenForm().navigationTitle("Filter").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { account = nil; category = nil; type = .all; sort = .newest; preset = .all; tag = nil; hideTransfers = false }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
    }
    private func label(_ s: TxnSort) -> String {
        switch s { case .newest: return "Newest first"; case .oldest: return "Oldest first"
        case .amountHigh: return "Amount: high → low"; case .amountLow: return "Amount: low → high" }
    }
}

// MARK: - Log / edit a transaction
struct LogTxnSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: Txn? = nil
    @State private var merchant = ""
    @State private var amount: Double = 0
    @State private var isIncome = false
    @State private var category = ""
    @State private var account = ""
    @State private var date = Date()
    @State private var tags: [String] = []
    @State private var transfer = false
    @State private var newTag = ""
    @State private var loaded = false

    private var suggestions: [String] {
        let known = Set(store.txns.flatMap(\.tags))
        return Array(known.subtracting(tags)).sorted().prefix(8).map { $0 }
    }
    private var categoryOptions: [String] {
        var seen = Set<String>()
        return (store.categories.map(\.name) + ["Income"]).filter { seen.insert($0).inserted }
    }
    private var accountOptions: [String] { store.accountNames.isEmpty ? ["—"] : store.accountNames }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledField(label: "Merchant", placeholder: "e.g. Swiggy", text: $merchant)
                    LabeledAmountField(label: "Amount", amount: $amount)
                    Picker("Type", selection: $isIncome) { Text("Spend").tag(false); Text("Income").tag(true) }
                        .pickerStyle(.segmented)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(categoryOptions, id: \.self) { Text($0) }
                    }
                    Picker("Account", selection: $account) {
                        ForEach(accountOptions, id: \.self) { Text($0) }
                    }
                    Toggle(isOn: $transfer) { Label("Transfer / card bill payment", systemImage: "arrow.left.arrow.right") }
                }
                Section {
                    if !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(tags, id: \.self) { t in
                                TagPill(text: t, removable: true) { tags.removeAll { $0 == t } } } }
                        }
                    }
                    HStack {
                        TextField("Add a tag", text: $newTag).autocorrectionDisabled()
                        Button("Add") { addTag(newTag); newTag = "" }.disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(suggestions, id: \.self) { s in
                                Button { addTag(s) } label: { TagPill(text: s) }.buttonStyle(.plain) } }
                        }
                    }
                } header: { Text("Tags") }
                if let e = editing, e.cardholder != nil || e.rewardLabel != nil || e.isInternational {
                    Section {
                        if let h = e.cardholder { LabeledContent("Add-on cardholder", value: h) }
                        if let fx = e.forexLabel { LabeledContent("Original amount", value: fx) }
                        else if e.isInternational { LabeledContent("International", value: "Yes") }
                        if let rl = e.rewardLabel { LabeledContent("Reward earned", value: rl) }
                    } header: { Text("Statement details") }
                }
                if let e = editing { DeleteSheetButton(noun: "transaction") { store.remove(txn: e); dismiss() } }
            }
            .zenForm()
            .navigationTitle(editing == nil ? "Add transaction" : "Edit transaction").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        let amt = abs(amount) * (isIncome ? 1 : -1)
                        let sym = store.categories.first { $0.name == category }?.symbol ?? (isIncome ? "indianrupeesign.circle.fill" : "circle.grid.2x2")
                        let cat = isIncome ? "Income" : category
                        if let e = editing {
                            store.update(Txn(id: e.id, merchant: merchant.isEmpty ? "Transaction" : merchant, symbol: sym,
                                             category: cat, account: account, amount: amt, date: date, externalId: e.externalId,
                                             source: e.source, counterparty: e.counterparty, statementId: e.statementId,
                                             statementRecordId: e.statementRecordId, tags: tags, transfer: transfer,
                                             cardholder: e.cardholder, reward: e.reward, rewardCurrency: e.rewardCurrency,
                                             forexCurrency: e.forexCurrency, forexAmount: e.forexAmount))
                        } else {
                            store.logTxn(Txn(merchant: merchant.isEmpty ? "Transaction" : merchant, symbol: sym,
                                             category: cat, account: account, amount: amt, date: date,
                                             tags: tags, transfer: transfer))
                        }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded else { return }; loaded = true
                if let e = editing {
                    merchant = e.merchant; amount = abs(e.amount); isIncome = e.income
                    category = e.category; account = e.account; date = e.date
                    tags = e.tags; transfer = e.transfer
                } else {
                    category = store.categories.first?.name ?? "Other"
                    account = store.accountNames.first ?? "—"
                }
            }
        }
    }
    private func addTag(_ t: String) {
        let v = t.trimmingCharacters(in: .whitespaces); guard !v.isEmpty, !tags.contains(v) else { return }
        tags.append(v)
    }
}

// MARK: - Upload statement (real PDF parser, supports locked PDFs)
struct UploadSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var pickedURL: URL?
    @State private var needsPassword = false
    @State private var password = ""
    @State private var parsing = false
    @State private var added: Int? = nil
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ZenBackground()
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        Image(systemName: added != nil ? "checkmark.seal.fill" : "doc.text.viewfinder")
                            .font(.system(size: 44)).foregroundStyle(added != nil ? Zen.green : Zen.accent)
                        Text(added != nil ? "Statement imported" : "Import a bank statement").font(.headline).foregroundStyle(Zen.ink)
                        Text(added != nil ? "\(added!) new transaction\(added! == 1 ? "" : "s") added & categorised"
                                          : "Pick a PDF (password-protected OK), CSV or Excel statement.")
                            .font(.caption).foregroundStyle(Zen.ink3).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 18).zenCard(24)

                    if needsPassword {
                        VStack(spacing: 10) {
                            Label("This PDF is locked", systemImage: "lock.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink2)
                            SecureField("PDF password", text: $password)
                                .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Unlock & import") { runParse() }
                                .buttonStyle(.glassProminent).tint(Zen.accent).disabled(password.isEmpty || parsing)
                        }
                        .padding(16).zenCard(20)
                    }

                    if parsing { ProgressView("Reading statement…").tint(Zen.accentDeep) }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Zen.caution).multilineTextAlignment(.center) }

                    if added == nil && !needsPassword {
                        Button { showPicker = true } label: { Label("Choose PDF, CSV or Excel", systemImage: "doc.badge.plus") }
                            .buttonStyle(.glassProminent).tint(Zen.accent).controlSize(.large).disabled(parsing)
                    }
                    if added != nil {
                        Button("Done") { dismiss() }.buttonStyle(.glassProminent).tint(Zen.accent).controlSize(.large)
                    }
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Import statement").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: importTypes) { result in
                error = nil; added = nil; password = ""; needsPassword = false
                switch result {
                case .success(let url):
                    pickedURL = url
                    if url.pathExtension.lowercased() == "pdf", StatementImporter.isLocked(url: url) { needsPassword = true }
                    else { runParse() }
                case .failure(let e): error = e.localizedDescription
                }
            }
        }
    }

    private var importTypes: [UTType] {
        var t: [UTType] = [.pdf, .commaSeparatedText, .plainText]
        if let xlsx = UTType(filenameExtension: "xlsx") { t.append(xlsx) }
        if let xls = UTType(filenameExtension: "xls") { t.append(xls) }
        if let s = UTType("org.openxmlformats.spreadsheetml.sheet") { t.append(s) }
        return t
    }

    private func runParse() {
        guard let url = pickedURL else { return }
        parsing = true; error = nil
        Task {
            do {
                let ext = url.pathExtension.lowercased()
                let isSpreadsheet = ["csv", "tsv", "txt", "xlsx", "xls"].contains(ext)
                let fileName = url.lastPathComponent
                let n: Int
                if isSpreadsheet {
                    let txns = try SpreadsheetImporter.parse(url: url)
                    n = store.mergeImport(ImportResult(txns: txns), record: StatementRecord(fileName: fileName, source: "Spreadsheet"))
                } else {
                    let result = try StatementImporter.parse(url: url, password: password.isEmpty ? nil : password)
                    n = store.mergeImport(result, record: StatementRecord(fileName: fileName, source: "Imported file"))
                }
                await MainActor.run { parsing = false; needsPassword = false; added = n }
            } catch StatementError.wrongPassword {
                await MainActor.run { parsing = false; needsPassword = true; error = StatementError.wrongPassword.errorDescription }
            } catch StatementError.locked {
                await MainActor.run { parsing = false; needsPassword = true }
            } catch {
                await MainActor.run { parsing = false; self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - Add / edit goal
struct AddGoalSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: Goal? = nil
    @State private var title = ""
    @State private var target: Double = 0
    @State private var saved: Double = 0
    @State private var monthly: Double = 0
    @State private var deadline = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var symbol = "star"
    @State private var allocations: [GoalAllocation] = []
    @State private var showAssetPicker = false
    @State private var loaded = false
    private let symbols = ["star","airplane","car","house","gift","laptopcomputer","heart","graduationcap","iphone","shield.lefthalf.filled"]

    private var allocTotal: Double { allocations.reduce(0) { $0 + store.allocationValue($1) } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Icon") { IconPicker(symbols: symbols, selection: $symbol) }
                Section {
                    LabeledField(label: "Title", placeholder: "e.g. Emergency fund", text: $title)
                    LabeledAmountField(label: "Target", amount: $target)
                    if allocations.isEmpty {
                        LabeledAmountField(label: "Saved so far", amount: $saved)
                    } else {
                        HStack {
                            Text("Saved so far").foregroundStyle(Zen.ink2)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(INR.full(allocTotal)).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                                Text("from \(allocations.count) asset\(allocations.count == 1 ? "" : "s")")
                                    .font(.caption2).foregroundStyle(Zen.ink3)
                            }
                        }
                    }
                    LabeledAmountField(label: "Monthly", amount: $monthly)
                    DatePicker("Target date", selection: $deadline, displayedComponents: .date)
                }
                Section {
                    ForEach(allocations) { a in
                        allocationRow(a)
                    }
                    .onDelete { idx in allocations.remove(atOffsets: idx) }
                    Button { showAssetPicker = true } label: {
                        Label("Allocate an asset", systemImage: "plus.circle")
                    }
                } header: { Text("Backing assets") }
                footer: {
                    Text(allocations.isEmpty
                         ? "Link FDs/RDs, investments, a bank balance, or cash. Progress then tracks their live value."
                         : "Saved updates automatically from these assets' current value.")
                }
                if let e = editing { DeleteSheetButton(noun: "goal") { store.remove(goal: e); dismiss() } }
            }
            .zenForm()
            .navigationTitle(editing == nil ? "New goal" : "Edit goal").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Create" : "Save") {
                        let g = Goal(id: editing?.id ?? UUID(), title: title.isEmpty ? "New goal" : title, symbol: symbol,
                                     saved: allocations.isEmpty ? saved : allocTotal, target: target > 0 ? target : 100000,
                                     monthly: monthly, deadline: deadline, status: editing?.status ?? .onTrack,
                                     allocations: allocations)
                        if editing == nil { store.addGoal(g) } else { store.update(g) }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showAssetPicker) {
                AssetAllocationPicker(existing: allocations) { allocations.append($0) }
            }
            .onAppear {
                guard !loaded, let e = editing else { loaded = true; return }; loaded = true
                title = e.title; target = e.target; saved = e.saved
                monthly = e.monthly; deadline = e.deadline; symbol = e.symbol
                allocations = e.allocations
            }
        }
    }

    @ViewBuilder private func allocationRow(_ a: GoalAllocation) -> some View {
        let idx = allocations.firstIndex { $0.id == a.id }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: a.kind.symbol).font(.caption).foregroundStyle(Zen.accentDeep).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.assetName(a)).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink).lineLimit(1)
                    Text(a.kind.label).font(.caption2).foregroundStyle(Zen.ink3)
                }
                Spacer()
                Text(INR.compact(store.allocationValue(a))).font(.caption.weight(.bold)).foregroundStyle(Zen.ink)
            }
            if let idx {
                if a.kind == .cash {
                    LabeledAmountField(label: "Amount", amount: Binding(get: { allocations[idx].amount },
                                                                        set: { allocations[idx].amount = $0 }))
                } else {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { allocations[idx].percent }, set: { allocations[idx].percent = $0 }), in: 0...100, step: 5)
                        Text("\(Int(a.percent))%").font(.caption.weight(.bold)).foregroundStyle(Zen.ink2).frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Asset allocation picker (add one backing asset to a goal)
struct AssetAllocationPicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var existing: [GoalAllocation] = []
    var onAdd: (GoalAllocation) -> Void

    @State private var cashAmount: Double = 0
    @State private var cashNote = ""

    private func used(_ kind: AllocationKind, _ id: UUID) -> Bool {
        existing.contains { $0.kind == kind && $0.assetId == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !store.deposits.isEmpty {
                    Section("Deposits") {
                        ForEach(store.deposits) { d in
                            assetRow(kind: .deposit, id: d.id, title: "\(d.bank) \(d.tag)",
                                     sub: d.maturesText, value: d.current)
                        }
                    }
                }
                if !store.investments.isEmpty {
                    Section("Investments") {
                        ForEach(store.investments) { inv in
                            assetRow(kind: .investment, id: inv.id, title: inv.name,
                                     sub: inv.kind.label, value: inv.currentValue)
                        }
                    }
                }
                if !store.banks.isEmpty {
                    Section("Bank balances") {
                        ForEach(store.banks) { b in
                            assetRow(kind: .bank, id: b.id, title: b.name, sub: "Balance", value: b.balance)
                        }
                    }
                }
                Section("Cash / manual") {
                    LabeledField(label: "Label", placeholder: "e.g. Gold, EPF, savings", text: $cashNote)
                    LabeledAmountField(label: "Amount", amount: $cashAmount)
                    Button {
                        onAdd(GoalAllocation(kind: .cash, percent: 100, amount: cashAmount, note: cashNote))
                        dismiss()
                    } label: { Label("Add cash amount", systemImage: "plus.circle") }
                        .disabled(cashAmount <= 0)
                }
            }
            .zenForm()
            .navigationTitle("Allocate asset").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    @ViewBuilder private func assetRow(kind: AllocationKind, id: UUID, title: String, sub: String, value: Double) -> some View {
        let already = used(kind, id)
        let committed = store.allocatedPercent(kind: kind, assetId: id)
        Button {
            // default to whatever share is still free (min 100% of remainder), at least show the picker default
            let free = max(0, 100 - committed)
            onAdd(GoalAllocation(kind: kind, assetId: id, percent: free > 0 ? min(100, free) : 100))
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol).font(.caption).foregroundStyle(already ? Zen.ink3 : Zen.accentDeep).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(already ? Zen.ink3 : Zen.ink).lineLimit(1)
                    Text(committed > 0 ? "\(sub) · \(Int(committed))% allocated elsewhere" : sub)
                        .font(.caption2).foregroundStyle(Zen.ink3)
                }
                Spacer()
                Text(INR.compact(value)).font(.caption.weight(.bold)).foregroundStyle(Zen.ink2)
            }
        }
        .buttonStyle(.plain)
        .disabled(already)
    }
}

// MARK: - Quick allocate one asset to a goal (no full form)
struct QuickAllocateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let kind: AllocationKind
    let assetId: UUID?
    let assetName: String
    let assetValue: Double
    @State private var percent: Double = 100

    private func allocatedHere(_ g: Goal) -> Bool {
        g.allocations.contains { $0.kind == kind && $0.assetId == assetId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: kind.symbol).foregroundStyle(Zen.accentDeep)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(assetName).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                            Text(INR.full(assetValue)).font(.caption2).foregroundStyle(Zen.ink3)
                        }
                    }
                    if kind != .cash {
                        HStack(spacing: 10) {
                            Text("Allocate").foregroundStyle(Zen.ink2)
                            Slider(value: $percent, in: 0...100, step: 5)
                            Text("\(Int(percent))%").font(.caption.weight(.bold)).frame(width: 42, alignment: .trailing)
                        }
                    }
                } footer: { Text("Pick a goal to back with \(kind == .cash ? "this amount" : "\(Int(percent))% of this asset").") }

                if store.goals.isEmpty {
                    Section { Text("No goals yet — create one first.").font(.caption).foregroundStyle(Zen.ink3) }
                } else {
                    Section("Goals") {
                        ForEach(store.goals) { g in
                            Button {
                                store.addAllocation(GoalAllocation(kind: kind, assetId: assetId, percent: percent,
                                                                   amount: kind == .cash ? assetValue : 0,
                                                                   note: kind == .cash ? assetName : ""), to: g)
                                dismiss()
                            } label: {
                                HStack {
                                    IconChip(symbol: g.symbol, size: 32)
                                    Text(g.title).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                                    Spacer()
                                    if allocatedHere(g) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Zen.green) }
                                    else { Image(systemName: "plus.circle").foregroundStyle(Zen.accentDeep) }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(allocatedHere(g))
                        }
                    }
                }
            }
            .zenForm()
            .navigationTitle("Allocate to goal").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Add / edit deposit
struct AddDepositSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: Deposit? = nil
    @State private var bank = ""
    @State private var amount: Double = 0
    @State private var rate: Double = 0
    @State private var isRD = false
    @State private var start = Date()
    @State private var maturity = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $isRD) { Text("Fixed (FD)").tag(false); Text("Recurring (RD)").tag(true) }
                        .pickerStyle(.segmented)
                    LabeledField(label: "Bank", placeholder: "e.g. HDFC", text: $bank)
                    LabeledAmountField(label: "Current value", amount: $amount)
                    HStack { Text("Interest rate").foregroundStyle(Zen.ink2); Spacer()
                        TextField("0", value: $rate, format: .number).multilineTextAlignment(.trailing).keyboardType(.decimalPad).frame(maxWidth: 80)
                        Text("%").foregroundStyle(Zen.ink3) }
                    DatePicker("Started", selection: $start, displayedComponents: .date)
                    DatePicker("Matures", selection: $maturity, displayedComponents: .date)
                }
                if let e = editing { DeleteSheetButton(noun: "deposit") { store.remove(deposit: e); dismiss() } }
            }
            .zenForm()
            .navigationTitle(editing == nil ? "Add deposit" : "Edit deposit").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        let d = Deposit(id: editing?.id ?? UUID(), bank: bank.isEmpty ? "Bank" : bank,
                                        tag: isRD ? "RD" : "FD", symbol: isRD ? "calendar" : "lock.fill",
                                        rate: rate, current: amount, startDate: start, maturityDate: maturity)
                        if editing == nil { store.addDeposit(d) } else { store.update(d) }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded, let e = editing else { loaded = true; return }; loaded = true
                bank = e.bank; amount = e.current; rate = e.rate
                isRD = e.tag == "RD"; start = e.startDate; maturity = e.maturityDate
            }
        }
    }
}

// MARK: - Add / edit investment (stocks & mutual funds) with autocomplete
struct AddInvestmentSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: Investment? = nil
    @State private var name = ""
    @State private var kind: InvestmentKind = .stock
    @State private var units: Double = 0
    @State private var avgCost: Double = 0
    @State private var lastPrice: Double = 0
    @State private var addUnits: Double = 0
    @State private var addPrice: Double = 0
    @State private var identifier = ""
    @State private var query = ""
    @State private var results: [InstrumentHit] = []
    @State private var searching = false
    @State private var picked = false
    @State private var searchTask: Task<Void, Never>?
    @State private var loaded = false
    @State private var country = MarketCatalog.default.country
    @State private var market = MarketCatalog.default

    var body: some View {
        NavigationStack {
            Form {
                Section { Picker("Type", selection: $kind) {
                    ForEach(InvestmentKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).onChange(of: kind) { _, _ in results = []; query = "" } }

                if !picked && kind.usesMarket {
                    Section {
                        Picker("Country", selection: $country) {
                            ForEach(MarketCatalog.countries, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: country) { _, c in
                            if let first = MarketCatalog.exchanges(c).first { market = first }
                            results = []; if query.count >= 2 { runSearch(query) }
                        }
                        Picker("Exchange", selection: $market) {
                            ForEach(MarketCatalog.exchanges(country), id: \.self) { Text($0.exchange).tag($0) }
                        }
                        .onChange(of: market) { _, _ in results = []; if query.count >= 2 { runSearch(query) } }
                    } header: { Text("Market") }
                }

                if !picked {
                    Section {
                        LabeledField(label: "Search",
                                     placeholder: kind == .mutualFund ? "e.g. Quant Small Cap" : "e.g. \(searchExample)",
                                     text: $query, autocaps: .never)
                        if searching { HStack { ProgressView(); Text("Searching…").foregroundStyle(Zen.ink3) } }
                        ForEach(results) { hit in
                            Button { pick(hit) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.name).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink)
                                    Text(hit.subtitle).font(.caption2).foregroundStyle(Zen.ink3)
                                }
                            }
                        }
                    } header: { Text("Find your \(kind.label.lowercased())") }
                    footer: { Text(kind.usesMarket
                        ? "Search \(market.exchange) (\(country)) — live from Yahoo Finance. Or fill the fields below manually."
                        : "Search by name — live from AMFI. Or fill the fields below manually.") }
                }

                Section {
                    LabeledField(label: "Name", placeholder: "Holding name", text: $name)
                    LabeledField(label: kind.idLabel, placeholder: kind == .mutualFund ? "scheme code" : "\(searchExample)\(market.suffix)",
                                 text: $identifier, autocaps: .characters)
                    unitsRow("Units" + (editing == nil ? " bought" : " held"), $units)
                    LabeledAmountField(label: editing == nil ? "Buy price / unit" : "Avg cost / unit", amount: $avgCost)
                } footer: {
                    Text("Current price loads automatically from \(kind == .mutualFund ? "AMFI" : "Yahoo Finance") for known holdings.")
                }

                if editing != nil {
                    Section {
                        unitsRow("Units bought", $addUnits)
                        LabeledAmountField(label: "Buy price / unit", amount: $addPrice)
                        Button { applyBuyMore() } label: { Label("Add to holding", systemImage: "plus.circle") }
                            .disabled(addUnits <= 0 || addPrice <= 0)
                    } header: { Text("Buy more") }
                    footer: { Text("Adds the units and re-computes your average cost automatically.") }
                }

                if let e = editing { DeleteSheetButton(noun: "investment") { store.remove(investment: e); dismiss() } }
            }
            .zenForm()
            .navigationTitle(editing == nil ? "Add investment" : "Edit investment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        let inv = Investment(id: editing?.id ?? UUID(), name: name.isEmpty ? "Holding" : name,
                                             kind: kind, units: units, avgCost: avgCost,
                                             identifier: identifier.trimmingCharacters(in: .whitespaces),
                                             lastPrice: lastPrice, lastUpdated: editing?.lastUpdated)
                        if editing == nil { store.addInvestment(inv) } else { store.update(inv) }
                        Task { await store.refreshQuotes() }   // auto-load current price/NAV
                        dismiss()
                    }.fontWeight(.semibold).disabled(name.isEmpty)
                }
            }
            .onChange(of: query) { _, q in runSearch(q) }
            .onAppear {
                guard !loaded else { return }; loaded = true
                guard let e = editing else { return }
                picked = true; name = e.name; kind = e.kind; units = e.units; avgCost = e.avgCost
                lastPrice = e.lastPrice; identifier = e.identifier
            }
        }
    }

    private var searchExample: String {
        switch country {
        case "India": return kind == .etf ? "Nippon Nifty BeES" : "Reliance, INFY"
        case "United States": return kind == .etf ? "VOO, QQQ" : "Apple, MSFT"
        default: return kind == .etf ? "ETF name" : "company name"
        }
    }

    private func unitsRow(_ label: String, _ value: Binding<Double>) -> some View {
        HStack { Text(label).foregroundStyle(Zen.ink2); Spacer()
            TextField("0", value: value, format: .number).multilineTextAlignment(.trailing).keyboardType(.decimalPad).frame(maxWidth: 120) }
    }
    /// Weighted-average a new purchase into the existing holding.
    private func applyBuyMore() {
        guard addUnits > 0, addPrice > 0 else { return }
        let total = units + addUnits
        if total > 0 { avgCost = (units * avgCost + addUnits * addPrice) / total }
        units = total; addUnits = 0; addPrice = 0
    }
    private func pick(_ hit: InstrumentHit) {
        name = hit.name; identifier = hit.identifier
        if let p = hit.price, p > 0 { lastPrice = p }
        picked = true; results = []; query = ""
    }

    private func runSearch(_ q: String) {
        searchTask?.cancel()
        let term = q.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { results = []; searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let hits = await QuoteProvider.shared.search(term, kind: kind, market: kind.usesMarket ? market : nil)
            if Task.isCancelled { return }
            await MainActor.run { results = hits; searching = false }
        }
    }
}

// MARK: - Connect bank (Account Aggregator)
struct ConnectBankSheet: View {
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showUpload = false
    var body: some View {
        NavigationStack {
            ZStack {
                ZenBackground()
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        Image(systemName: "building.columns").font(.system(size: 40)).foregroundStyle(Zen.accent)
                        Text("Link via Account Aggregator").font(.headline).foregroundStyle(Zen.ink)
                        Text(sync.isConfigured
                             ? "You'll approve read-only access in your Account Aggregator app. Win the Money never sees your bank login."
                             : "Add your Setu credentials in Bank sync settings to connect — or import a statement / add accounts manually instead.")
                            .font(.caption).foregroundStyle(Zen.ink3).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 18).zenCard(24)

                    SyncStatus(phase: sync.phase)

                    if sync.isConfigured {
                        Button { sync.sync(into: store) } label: {
                            Label("Continue with Account Aggregator", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.glassProminent).tint(Zen.accent).controlSize(.large).disabled(sync.isWorking)
                    }
                    Button { showUpload = true } label: { Label("Import a statement instead", systemImage: "doc.text") }
                        .font(.subheadline)
                    NavigationLink { BankSyncSettingsView() } label: {
                        Label(sync.isConfigured ? "Bank sync settings" : "Set up Setu credentials", systemImage: "gearshape")
                    }.font(.subheadline)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Link account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showUpload) { UploadSheet() }
            .onChange(of: sync.phase) { _, p in
                if case .success = p { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() } }
            }
        }
    }
}

// MARK: - Settings (functional)
struct SettingsSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var gmail: GmailManager
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var ai: AIManager
    @EnvironmentObject var lock: AppLock
    @Environment(\.dismiss) private var dismiss
    @State private var lockError: String?
    @State private var showExportJSON = false
    @State private var showExportCSV = false
    @State private var showExportTxnJSON = false
    @State private var showImport = false
    @State private var showImportChoice = false
    @State private var pendingImportURL: URL?
    @State private var message: String?
    @State private var showClearConfirm = false
    @State private var clearAfterExport = false

    var body: some View {
        NavigationStack {
            List {
                profileHeader
                profileSection
                connectionsSection
                securitySection
                SiriSettingsSection()
                notificationsSection
                backupSection
                dataSection
                dangerSection
                aboutSection
            }
            .zenForm()
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fileExporter(isPresented: $showExportJSON, document: BackupFile(store.exportBundle()),
                          contentType: .json, defaultFilename: "WinTheMoney-backup-\(stamp())") { result in
                if case .success = result {
                    if clearAfterExport { performClear(); message = "Backup saved, all data cleared" }
                    else { message = "Backup exported" }
                }
                clearAfterExport = false
            }
            .fileExporter(isPresented: $showExportCSV, document: CSVFile(TxnExporter.csv(store.txns)),
                          contentType: .commaSeparatedText, defaultFilename: "WinTheMoney-transactions-\(stamp())") { _ in message = "CSV exported" }
            .fileExporter(isPresented: $showExportTxnJSON, document: BackupFile(TxnExporter.json(store.txns)),
                          contentType: .json, defaultFilename: "WinTheMoney-transactions-\(stamp())") { _ in message = "Transactions JSON exported" }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { pendingImportURL = url; showImportChoice = true }
            }
            .confirmationDialog("Import backup", isPresented: $showImportChoice, titleVisibility: .visible) {
                Button("Replace all data", role: .destructive) { doImport(replace: true) }
                Button("Merge with existing") { doImport(replace: false) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Replace your current data, or merge the backup into it?") }
            .confirmationDialog("Clear all data?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Back up first, then clear") { clearAfterExport = true; showExportJSON = true }
                Button("Clear without backup", role: .destructive) { performClear() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This disconnects Gmail, deletes imported statements & saved passwords, removes all accounts, cards, transactions, goals and income, and resets every setting. Your saved backups are kept.") }
        }
    }

    /// Full wipe: store data + preferences, Gmail account/statements, and Setu credentials.
    private func performClear() {
        store.clearAll(); gmail.reset(); sync.reset(); ai.reset(); message = "All data cleared"
    }

    @ViewBuilder private var profileHeader: some View {
        Section {
            HStack(spacing: 14) {
                Group {
                    if store.userName.isEmpty { Image(systemName: "person.fill").font(.title2) }
                    else { Text(String(store.userName.prefix(1))).font(.title.weight(.bold)) }
                }
                .foregroundStyle(.white).frame(width: 52, height: 52).background(Circle().fill(Zen.calmGradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.userName.isEmpty ? "Your profile" : store.userName).font(.title3.weight(.bold)).foregroundStyle(Zen.ink)
                    Text("Level \(store.level) · \(store.levelName) · \(store.xp) XP").font(.caption).foregroundStyle(Zen.ink3)
                }
            }.listRowBackground(Color.clear)
        }
    }

    @ViewBuilder private var profileSection: some View {
        Section("Profile") {
            HStack { Text("Name").foregroundStyle(Zen.ink2); Spacer()
                TextField("Your name", text: $store.userName).multilineTextAlignment(.trailing) }
            HStack { Text("Net-worth goal (₹)").foregroundStyle(Zen.ink2); Spacer()
                TextField("", value: $store.netWorthTarget, format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 130) }
        }
    }

    @ViewBuilder private var connectionsSection: some View {
        Section {
            NavigationLink { AccountsView(embedded: true) } label: { Label("Manage accounts", systemImage: "creditcard") }
            NavigationLink { RecurringView() } label: { Label("Recurring transfers", systemImage: "arrow.triangle.2.circlepath") }
            NavigationLink { MerchantsView() } label: { Label("Merchants & rules", systemImage: "tag") }
            NavigationLink { StatementsView() } label: {
                Label("Imported statements", systemImage: "doc.text.magnifyingglass")
                    .badge(store.statements.count)
            }
            NavigationLink { ConflictsView() } label: {
                HStack {
                    Label("Conflicts to review", systemImage: "exclamationmark.triangle")
                    if !store.unresolvedConflicts.isEmpty {
                        Spacer()
                        Text("\(store.unresolvedConflicts.count)").font(.caption.weight(.bold))
                            .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color(hex: "9AA7BE"), in: Capsule())
                    }
                }
            }
            Button { store.recategorizeAll(); message = "Re-scanned categories" } label: { Label("Re-scan categories", systemImage: "wand.and.stars") }
            NavigationLink { GmailSettingsView() } label: { Label("Email auto-import · Gmail", systemImage: "envelope.badge") }
            NavigationLink { AISettingsView() } label: { Label("AI insights & providers", systemImage: "sparkles") }
            Toggle(isOn: $store.accountAggregatorEnabled) { Label("Account Aggregator (Setu)", systemImage: "building.columns") }
            if store.accountAggregatorEnabled {
                NavigationLink { BankSyncSettingsView() } label: { Label("Bank sync settings", systemImage: "gearshape") }
            }
        } header: { Text("Accounts & data") }
        footer: { Text("Account Aggregator is off by default. Turn it on to connect banks via Setu; otherwise no AA sync ever runs.") }
    }

    @ViewBuilder private var securitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { lock.enabled },
                set: { want in
                    if want {
                        // Refuse to enable if we can't authenticate — avoids locking the user out.
                        let check = lock.canAuthenticate()
                        guard check.ok else { lockError = check.reason; return }
                    }
                    lockError = nil
                    lock.enabled = want
                }
            )) { Label("App lock (Face ID)", systemImage: "faceid") }
            if lock.enabled {
                Picker(selection: $lock.grace) {
                    ForEach(AppLock.Grace.allCases) { Text($0.label).tag($0) }
                } label: { Label("Require unlock", systemImage: "clock") }
            }
            if let lockError { Text(lockError).font(.caption).foregroundStyle(Zen.caution) }
        } header: { Text("Security") } footer: {
            Text("Locks the app with Face ID / Touch ID (passcode fallback) and hides balances in the app switcher. Home-screen widgets can still show numbers — iOS renders them outside the app.")
        }
    }

    @ViewBuilder private var notificationsSection: some View {
        Section("Notifications") {
            Toggle(isOn: $store.notificationsEnabled) { Label("Monthly budget reminder", systemImage: "bell") }
                .onChange(of: store.notificationsEnabled) { _, v in NotificationManager.setEnabled(v) }
        }
    }

    @ViewBuilder private var backupSection: some View {
        Section {
            Toggle(isOn: $store.autoBackupEnabled) { Label("Auto-backup", systemImage: "clock.arrow.circlepath") }
            Button { message = "Backed up to \(store.backupNow())" } label: { Label("Back up now", systemImage: "icloud.and.arrow.up") }
            Button { message = store.restoreLatestBackup() ? "Restored latest backup" : "No backup found yet" } label: { Label("Restore latest backup", systemImage: "icloud.and.arrow.down") }
            NavigationLink { BackupsView() } label: { Label("Backups", systemImage: "clock.badge.checkmark") }
        } header: { Text("Automatic backup") } footer: {
            Text(backupFooter)
        }
    }

    private var backupFooter: String {
        var s = BackupManager.iCloudAvailable
            ? "Backs up automatically to iCloud Drive and the Files app."
            : "Backs up automatically to the Files app (On My iPhone), included in your device's iCloud backup. Sign in to iCloud to also sync via iCloud Drive."
        if let d = BackupManager.lastBackup { s += " Last backup: \(d.formatted(date: .abbreviated, time: .shortened))." }
        return s
    }

    @ViewBuilder private var dataSection: some View {
        Section {
            Button { showExportJSON = true } label: { Label("Export backup (JSON)", systemImage: "square.and.arrow.up") }
            Button { showImport = true } label: { Label("Import backup (JSON)", systemImage: "square.and.arrow.down") }
            Button { showExportCSV = true } label: { Label("Export transactions (CSV)", systemImage: "tablecells") }
            Button { showExportTxnJSON = true } label: { Label("Export transactions (JSON)", systemImage: "curlybraces") }
            if let message { Text(message).font(.caption).foregroundStyle(Zen.greenDeep) }
        } header: { Text("Manual export / import") } footer: {
            Text("Export everything to a file you choose (e.g. iCloud Drive), then import it on a new device. Secrets (API keys) are not included.")
        }
    }

    @ViewBuilder private var dangerSection: some View {
        Section {
            Button(role: .destructive) { showClearConfirm = true } label: {
                Label("Clear all data", systemImage: "trash")
            }
        } footer: {
            Text("Permanently removes everything on this device. You'll be offered the chance to save a backup first.")
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "1.0")
        }
    }

    private func doImport(replace: Bool) {
        guard let url = pendingImportURL else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { message = "Couldn't read that file"; return }
        message = store.importBundle(data, replace: replace) ? "Backup imported" : "That file isn't a valid backup"
    }
}

// MARK: - Rotating backups: browse, preview contents, restore one
struct BackupsView: View {
    @EnvironmentObject var store: Store
    @State private var items: [BackupManager.BackupInfo] = []
    @State private var selected: BackupManager.BackupInfo?

    var body: some View {
        List {
            if items.isEmpty {
                Text("No backups yet.").foregroundStyle(Zen.ink3)
            }
            ForEach(items) { info in
                Button { selected = info } label: { row(info) }
                    .buttonStyle(.plain)
            }
        }
        .zenForm()
        .navigationTitle("Backups")
        .onAppear { items = BackupManager.list() }
        .sheet(item: $selected) { info in
            BackupPreviewSheet(info: info) { items = BackupManager.list() }
        }
    }

    private func row(_ info: BackupManager.BackupInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.date.formatted(date: .abbreviated, time: .shortened))
                HStack(spacing: 6) {
                    Text(info.source.rawValue)
                    if info.isStable { Text("· Latest") }
                    if info.isPreRestore { Text("· Before restore") }
                }
                .font(.caption).foregroundStyle(Zen.ink3)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(info.byteSize), countStyle: .file))
                .font(.caption).foregroundStyle(Zen.ink3)
        }
    }
}

/// Shows what a backup actually contains next to the live data, before replacing anything.
struct BackupPreviewSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let info: BackupManager.BackupInfo
    var onRestore: () -> Void
    @State private var summary: Store.BackupSummary?
    @State private var loaded = false
    @State private var confirm = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if let s = summary {
                    Section("This backup") {
                        compare("Transactions", s.txns, store.txns.count)
                        compare("Bank accounts", s.banks, store.banks.count)
                        compare("Cards", s.cards, store.cards.count)
                        compare("Deposits", s.deposits, store.deposits.count)
                        compare("Goals", s.goals, store.goals.count)
                        compare("Investments", s.investments, store.investments.count)
                    }
                    if let f = s.firstTxn, let l = s.lastTxn {
                        Section("Transaction dates") {
                            Text("\(f.formatted(date: .abbreviated, time: .omitted)) — \(l.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    Section {
                        Button(role: .destructive) { confirm = true } label: {
                            Label("Restore this backup", systemImage: "arrow.counterclockwise")
                        }
                    } footer: {
                        Text("Replaces all current data with this backup. A snapshot of your current data is saved first, labelled “Before restore”.")
                    }
                } else if loaded {
                    Section { Text("This file is corrupt and can't be restored.").foregroundStyle(Zen.caution) }
                } else {
                    Section { Text("Reading…").foregroundStyle(Zen.ink3) }
                }
                if let message { Text(message).font(.caption).foregroundStyle(Zen.greenDeep) }
            }
            .zenForm()
            .navigationTitle(info.date.formatted(date: .abbreviated, time: .shortened))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                summary = BackupManager.data(at: info.url).flatMap { store.previewBackup($0) }
                loaded = true
            }
            .confirmationDialog("Restore this backup?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Replace all data", role: .destructive) {
                    if store.restoreBackup(info) { onRestore(); dismiss() }
                    else { message = "Couldn't read that backup" }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your current data will be replaced by this backup.") }
        }
    }

    private func compare(_ label: String, _ backup: Int, _ live: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(backup)")
            Text("now \(live)").font(.caption).foregroundStyle(Zen.ink3)
        }
    }
}

// MARK: - Gmail email auto-import
struct GmailSettingsView: View {
    @EnvironmentObject var gmail: GmailManager
    @EnvironmentObject var store: Store
    var body: some View {
        Form {
            Section {
                if gmail.connected {
                    Label("Gmail connected", systemImage: "checkmark.seal.fill").foregroundStyle(Zen.greenDeep)
                    Button { gmail.scan(into: store) } label: { Label("Scan emails now", systemImage: "envelope.arrow.triangle.branch") }
                        .disabled(gmail.isWorking)
                    Button { gmail.rescanAll(into: store) } label: { Label("Re-scan all emails", systemImage: "arrow.clockwise") }
                        .disabled(gmail.isWorking)
                    Button(role: .destructive) { gmail.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                } else {
                    Button { gmail.connect() } label: { Label("Connect Gmail", systemImage: "envelope.badge") }
                        .disabled(!gmail.isConfigured || gmail.isWorking)
                }
                SyncStatus(phase: gmailPhase)
            } header: { Text("Auto-import from transaction alerts") }
            footer: { Text("Reads only bank & credit-card alert emails (read-only) and turns them into transactions. HDFC, ICICI, Axis and Scapia-Federal supported — including salary credits, standing-instruction auto-debits (loan EMI, card autopay) and debit-card spends.") }

            Section {
                Toggle(isOn: $gmail.autoScan) { Label("Auto-scan in background", systemImage: "clock.arrow.2.circlepath") }
                // The longer windows are what make a real backfill possible: the parser understands
                // wordings each bank retired years ago, but a 180-day ceiling means those mails are
                // never fetched. Long windows stay cheap because the processed-message ledger skips
                // anything already read.
                Picker("Look back", selection: $gmail.scanDays) {
                    Text("30 days").tag(30); Text("60 days").tag(60); Text("90 days").tag(90)
                    Text("180 days").tag(180); Text("1 year").tag(365); Text("2 years").tag(730)
                    Text("5 years").tag(1825); Text("All mail").tag(36500)
                }.onChange(of: gmail.scanDays) { _, _ in gmail.saveConfig() }
                if let d = gmail.lastScan { LabeledContent("Last scan", value: d.formatted(date: .abbreviated, time: .shortened)) }
            } header: { Text("Scan window") } footer: {
                Text("Auto-scan refreshes on app open (hourly at most) and periodically in the background when iOS allows. Already-scanned emails are skipped, so re-scans are quick. Use “Re-scan all” to re-read everything in the window — widen it first to backfill older history.")
            }

            Section {
                NavigationLink { StatementsEmailView() } label: {
                    HStack { Label("Statements from email", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        if !gmail.pending.isEmpty { Text("\(gmail.pending.count)").font(.caption.weight(.bold)).foregroundStyle(Zen.caution) }
                    }
                }
            } footer: { Text("Finds bank & card statement PDFs in your inbox, unlocks them with your saved passwords, and reconciles them against the alert transactions (adds real categories, rewards and exact figures).") }

            Section {
                if gmail.isConfigured {
                    LabeledContent("OAuth client", value: "Configured")
                } else {
                    Label("Not configured", systemImage: "exclamationmark.triangle").foregroundStyle(Zen.caution)
                    Text("Add your Google OAuth client ID to the app's Info.plist (key GIDClientID) and a matching URL scheme, then rebuild. It's a public client ID, configured at build time — not entered here.")
                        .font(.caption).foregroundStyle(Zen.ink3)
                }
            } header: { Text("Setup") } footer: {
                Text("One-time in Google Cloud Console: create a project, enable the Gmail API, set up the OAuth consent screen (add yourself as a test user, scope gmail.readonly), then create an OAuth client ID of type iOS with bundle id com.suhail.WinTheMoney.")
            }
        }
        .zenForm().navigationTitle("Gmail import").navigationBarTitleDisplayMode(.inline)
    }

    private var gmailPhase: SyncManager.Phase {
        switch gmail.phase {
        case .idle: return .idle
        case .working(let m): return .working(m)
        case .success(let n): return .success(n)
        case .failed(let m): return .failed(m)
        }
    }
}

// MARK: - Statements from email (vault + pending unlock)
struct StatementsEmailView: View {
    @EnvironmentObject var gmail: GmailManager
    @EnvironmentObject var store: Store
    @State private var newPassword = ""
    @State private var unlocking: PendingStatement?
    @State private var enteredPw = ""
    @State private var unlockMessage: String? = nil

    private var stmtPhase: SyncManager.Phase {
        switch gmail.stmtPhase {
        case .idle: return .idle; case .working(let m): return .working(m)
        case .success(let n): return .success(n); case .failed(let m): return .failed(m)
        }
    }
    var body: some View {
        Form {
            Section {
                Button { gmail.scanStatements(into: store) } label: { Label("Scan statements now", systemImage: "doc.text.magnifyingglass") }
                    .disabled(!gmail.connected)
                Toggle(isOn: $gmail.statementAutoScan) { Label("Auto-scan in background", systemImage: "clock.arrow.2.circlepath") }
                if let d = gmail.lastStatementScan { LabeledContent("Last scan", value: d.formatted(date: .abbreviated, time: .shortened)) }
                SyncStatus(phase: stmtPhase)
            } footer: { Text(gmail.connected ? "Reads statement PDFs from your inbox and reconciles them with your transactions." : "Connect Gmail first.") }

            if !gmail.pending.isEmpty {
                Section {
                    ForEach(gmail.pending) { p in
                        Button { unlocking = p; enteredPw = ""; unlockMessage = nil } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.filename).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink).lineLimit(1)
                                    Text(p.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(Zen.ink3)
                                }
                                Spacer()
                                Image(systemName: "lock").foregroundStyle(Zen.caution)
                            }
                        }
                        .swipeActions { Button(role: .destructive) { gmail.dismissPending(p) } label: { Label("Dismiss", systemImage: "trash") } }
                    }
                } header: { Text("Needs password") } footer: { Text("These couldn't be opened with your saved passwords. Tap to enter the password for each (e.g. Scapia's per-statement password).") }
            }

            Section {
                ForEach(StatementVault.passwords(), id: \.self) { pw in
                    HStack { Text(String(repeating: "•", count: max(4, pw.count))).foregroundStyle(Zen.ink2); Spacer()
                        Button(role: .destructive) { StatementVault.remove(pw); bump() } label: { Image(systemName: "minus.circle") } }
                }
                HStack {
                    SecureField("Add a password", text: $newPassword)
                    Button("Add") { StatementVault.add(newPassword); newPassword = ""; bump() }.disabled(newPassword.isEmpty)
                }
            } header: { Text("Saved passwords") } footer: {
                Text("Tried automatically when opening locked statements. Stored securely in the Keychain, never in backups.")
            }
        }
        .zenForm().navigationTitle("Statements from email").navigationBarTitleDisplayMode(.inline)
        .alert("Unlock statement", isPresented: Binding(get: { unlocking != nil }, set: { if !$0 { unlocking = nil } })) {
            SecureField("Password", text: $enteredPw)
            Button("Import") {
                guard let p = unlocking else { return }
                if let err = gmail.importPending(p, password: enteredPw, into: store) {
                    unlockMessage = err.errorDescription
                    // Only a wrong / still-locked password is worth retrying; any other error means the
                    // statement opened but couldn't be parsed and has already left the queue.
                    switch err { case .wrongPassword, .locked: break; default: unlocking = nil }
                } else { unlocking = nil }
            }
            Button("Cancel", role: .cancel) { unlocking = nil }
        } message: { Text(unlockMessage ?? "Enter the password for \(unlocking?.filename ?? "this statement").") }
    }
    @State private var refresh = false
    private func bump() { refresh.toggle() }
}

// MARK: - Add / edit bank account
struct AddBankSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: BankAccount? = nil
    @State private var name = ""
    @State private var type = "Savings"
    @State private var mask = ""
    @State private var balance: Double = 0
    @State private var bankCode: String? = nil
    @State private var imageRef: String? = nil
    @State private var loaded = false
    private let types = ["Savings", "Salary", "Current", "Wallet"]
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Bank", selection: $bankCode) {
                        Text("Other / not listed").tag(String?.none)
                        ForEach(BankCatalog.sorted, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                    }
                    .onChange(of: bankCode) { _, code in if let i = BankCatalog.info(code), name.isEmpty || BankCatalog.match(name: name) != nil { name = i.name } }
                    LabeledField(label: "Account name", placeholder: "e.g. HDFC Savings", text: $name)
                    Picker("Type", selection: $type) { ForEach(types, id: \.self) { Text($0) } }
                    LabeledField(label: "Last 4 digits", placeholder: "0000", text: $mask, keyboard: .numberPad)
                    LabeledAmountField(label: "Current balance", amount: $balance)
                }
                Section {
                    HStack { Text("Preview").foregroundStyle(Zen.ink2); Spacer()
                        BankBadge(monogram: BankCatalog.info(bankCode)?.code ?? String(name.prefix(4)).uppercased(),
                                  colorHex: BankCatalog.info(bankCode)?.colorHex ?? editing?.colorHex ?? "4F7FC4",
                                  imageRef: imageRef, size: 44) }
                    ImageRefRow(imageRef: $imageRef)
                } header: { Text("Logo (optional)") } footer: { Text("No bank logos are bundled — add your own image, or keep the brand-colour monogram.") }
                if let e = editing { DeleteSheetButton(noun: "account") { store.remove(bank: e); dismiss() } }
            }
            .zenForm().navigationTitle(editing == nil ? "Add account" : "Edit account").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        let info = BankCatalog.info(bankCode)
                        // A manual balance is the user asserting "this is my balance right now", so
                        // anchor it to now — future alert transactions then build on it.
                        let b = BankAccount(id: editing?.id ?? UUID(), name: name.isEmpty ? "Account" : name,
                                            logo: info?.code ?? String(name.prefix(4)).uppercased(),
                                            colorHex: info?.colorHex ?? editing?.colorHex ?? "4F7FC4",
                                            type: type, mask: String(mask.suffix(4)), balance: balance,
                                            bankCode: bankCode, ifsc: editing?.ifsc, branch: editing?.branch,
                                            tier: editing?.tier, imageRef: imageRef,
                                            balanceAnchor: balance, balanceAsOf: Date())
                        if editing == nil { store.addBank(b) } else { store.update(b) }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded, let e = editing else { loaded = true; return }; loaded = true
                name = e.name; type = e.type; mask = e.mask; balance = e.balance
                bankCode = e.bankCode; imageRef = e.imageRef
            }
        }
    }
}

// MARK: - Add / edit credit card
struct AddCardSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: CreditCard? = nil
    @State private var name = ""
    @State private var mask = ""
    @State private var outstanding: Double = 0
    @State private var limit: Double = 0
    @State private var bankCode: String? = nil
    @State private var network: String? = nil
    @State private var tier: String? = nil
    @State private var colorHex: String? = nil
    @State private var imageRef: String? = nil
    @State private var selectedProduct = ""   // catalog chooser (separate from the editable name)
    @State private var loaded = false

    /// Distinct product names for the chosen issuer (Scapia lists Visa+RuPay under one name).
    private var products: [String] {
        var seen = Set<String>()
        return CardCatalog.cards(for: bankCode).map(\.name).filter { seen.insert($0).inserted }
    }
    private var previewCard: CreditCard {
        CreditCard(name: name.isEmpty ? "Card" : name, mask: mask.isEmpty ? "0000" : String(mask.suffix(4)),
                   outstanding: outstanding, limit: max(1, limit), bankCode: bankCode, network: network,
                   tier: tier, colorHex: colorHex, imageRef: imageRef)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CardCoverView(card: previewCard, bankName: BankCatalog.info(bankCode)?.name ?? (name.isEmpty ? "Card" : name))
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    Picker("Issuer", selection: $bankCode) {
                        Text("Other").tag(String?.none)
                        ForEach(BankCatalog.sorted, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                    }
                    .onChange(of: bankCode) { _, _ in selectedProduct = "" }
                    Picker("Card", selection: $selectedProduct) {
                        Text("Custom").tag("")
                        ForEach(products, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: selectedProduct) { _, n in
                        guard let hit = CardCatalog.all.first(where: { $0.name == n }) else { return }
                        name = hit.name; network = hit.network; tier = hit.tier; colorHex = hit.gradient.first
                        if bankCode == nil { bankCode = hit.bankCode }
                    }
                    LabeledField(label: "Card name", placeholder: "e.g. HDFC Millennia", text: $name)
                    LabeledField(label: "Last 4 digits", placeholder: "0000", text: $mask, keyboard: .numberPad)
                    LabeledAmountField(label: "Outstanding", amount: $outstanding)
                    LabeledAmountField(label: "Credit limit", amount: $limit)
                }
                Section { ImageRefRow(imageRef: $imageRef) } header: { Text("Card image (optional)") }
                    footer: { Text("No card artwork is bundled — add your own image, or keep the generated gradient cover.") }
                if let e = editing { DeleteSheetButton(noun: "card") { store.remove(card: e); dismiss() } }
            }
            .zenForm().navigationTitle(editing == nil ? "Add card" : "Edit card").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        let c = CreditCard(id: editing?.id ?? UUID(), name: name.isEmpty ? "Card" : name,
                                           mask: String(mask.suffix(4)), outstanding: outstanding, limit: max(1, limit),
                                           bankCode: bankCode, network: network, tier: tier, colorHex: colorHex, imageRef: imageRef)
                        if editing == nil { store.addCard(c) } else { store.update(c) }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded, let e = editing else { loaded = true; return }; loaded = true
                name = e.name; mask = e.mask; outstanding = e.outstanding; limit = e.limit
                bankCode = e.bankCode; network = e.network; tier = e.tier; colorHex = e.colorHex; imageRef = e.imageRef
            }
        }
    }
}

// MARK: - Add / edit budget category
struct AddCategorySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: BudgetCategory? = nil
    @State private var name = ""
    @State private var plan: Double = 0
    @State private var symbol = "cart.fill"
    @State private var period: BudgetPeriod = .monthly
    @State private var customMonths = 6
    @State private var kind: CategoryKind = .needs
    @State private var hasAnchor = false
    @State private var anchor = Store.financialYearStart()
    @State private var loaded = false
    private let symbols = ["house.fill","cart.fill","fork.knife","car.fill","bag.fill","heart.fill","play.rectangle.fill","graduationcap.fill","airplane","gift.fill","pawprint.fill","gamecontroller.fill","shield.lefthalf.filled"]
    private let colors = ["6E9BD8","7FC4A3","5BA585","4F7FC4","9AA7BE"]
    private var isSystem: Bool { editing?.isSystem ?? false }
    private var budgetLabel: String { period == .monthly ? "Monthly budget" : "Budget / \(period == .custom ? "\(max(1,customMonths)) months" : period.noun)" }
    private var perMonth: Double { plan / Double(period == .custom ? max(1, customMonths) : period.months) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Icon") { IconPicker(symbols: symbols, selection: $symbol) }
                Section {
                    if isSystem {
                        HStack { Text("Category").foregroundStyle(Zen.ink2); Spacer(); Text(name).foregroundStyle(Zen.ink) }
                    } else {
                        LabeledField(label: "Category name", placeholder: "e.g. Groceries", text: $name)
                    }
                    LabeledAmountField(label: budgetLabel, amount: $plan)
                } footer: {
                    if isSystem { Text("This is a built-in category — its name can't be changed, but you can set its budget and icon.") }
                }

                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(CategoryKind.allCases) { Text($0.label + "s").tag($0) }
                    }
                } footer: {
                    Text("Investments are excluded from your overall spend totals, but still tracked here with their own budget and progress bar.")
                }

                Section {
                    Picker("Cap period", selection: $period) {
                        ForEach(BudgetPeriod.allCases) { Text($0.label).tag($0) }
                    }
                    if period == .custom {
                        Stepper("Every \(customMonths) month\(customMonths == 1 ? "" : "s")", value: $customMonths, in: 1...36)
                    }
                    if period == .annual || period == .custom {
                        Toggle("Set a cycle start date", isOn: $hasAnchor)
                        if hasAnchor {
                            DatePicker("Cycle starts", selection: $anchor, displayedComponents: .date)
                        }
                    }
                } header: { Text("Cap window") } footer: {
                    Text(period == .monthly
                         ? "Spending resets at the start of each month."
                         : "Tracks spend across the whole \(period == .custom ? "\(max(1,customMonths))-month" : period.noun) window — useful for insurance, fees or yearly subscriptions. ≈ \(INR.compact(perMonth))/month against your overall plan." + (hasAnchor ? "" : " Cycle aligns to the financial year (Apr–Mar) unless you set a start date."))
                }

                if let e = editing, !isSystem { DeleteSheetButton(noun: "category") { store.remove(category: e); dismiss() } }
            }
            .zenForm().navigationTitle(editing == nil ? "Add category" : "Edit category").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        let c = BudgetCategory(id: editing?.id ?? UUID(), name: name.isEmpty ? "Category" : name,
                                               symbol: symbol, spent: editing?.spent ?? 0, plan: plan,
                                               color: editing?.color ?? (colors.randomElement() ?? "6E9BD8"),
                                               isSystem: editing?.isSystem ?? false,
                                               period: period, customMonths: max(1, customMonths),
                                               anchor: (period == .annual || period == .custom) && hasAnchor ? anchor : nil,
                                               kind: kind)
                        if editing == nil { store.addCategory(c) } else { store.update(c) }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded, let e = editing else { loaded = true; return }; loaded = true
                name = e.name; plan = e.plan; symbol = e.symbol
                period = e.period; customMonths = e.customMonths; kind = e.kind
                if let a = e.anchor { anchor = a; hasAnchor = true }
            }
        }
    }
}

// MARK: - Add / edit income stream (multi-currency, linked account, credit day)
struct AddIncomeStreamSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var editing: IncomeStream? = nil
    @State private var name = ""
    @State private var amount: Double = 0
    @State private var currency = "INR"
    @State private var monthly = true
    @State private var accountId: UUID? = nil
    @State private var hasCreditDay = false
    @State private var creditDay = 1
    @State private var symbol = "laptopcomputer"
    @State private var loaded = false
    private let symbols = ["laptopcomputer","building.2","indianrupeesign.circle","paintbrush","briefcase","chart.line.uptrend.xyaxis","dollarsign.circle"]

    private var inrPreview: Double { amount * (monthly ? 12 : 1) * store.fxRate(currency) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Icon") { IconPicker(symbols: symbols, selection: $symbol, tint: Zen.greenDeep) }
                Section {
                    LabeledField(label: "Source", placeholder: "e.g. Salary — AKA", text: $name)
                    Picker("Currency", selection: $currency) { ForEach(Currencies.common, id: \.self) { Text($0) } }
                    Picker("Paid", selection: $monthly) { Text("Monthly").tag(true); Text("Yearly").tag(false) }.pickerStyle(.segmented)
                    LabeledAmountField(label: monthly ? "Amount / month" : "Amount / year", amount: $amount, currency: currency)
                } footer: {
                    if currency != "INR" {
                        Text("≈ \(INR.compact(inrPreview))/yr at today's rate (₹\(String(format: "%.2f", store.fxRate(currency)))/\(currency)). Updates live.")
                    }
                }
                Section("Credited to") {
                    Picker("Account", selection: $accountId) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.banks) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Toggle("Monthly salary (fixed day)", isOn: $hasCreditDay)
                    if hasCreditDay {
                        Picker("Credited on day", selection: $creditDay) { ForEach(1...31, id: \.self) { Text("\($0)") } }
                    }
                }
                if let e = editing { DeleteSheetButton(noun: "income source") { store.remove(stream: e); dismiss() } }
            }
            .zenForm().navigationTitle(editing == nil ? "Add income" : "Edit income").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") {
                        let annual = monthly ? amount * 12 : amount
                        let s = IncomeStream(id: editing?.id ?? UUID(), name: name.isEmpty ? "Income" : name,
                                             symbol: symbol, annual: annual, currency: currency, monthly: monthly,
                                             accountId: accountId, creditDay: hasCreditDay ? creditDay : nil)
                        if editing == nil { store.addIncomeStream(s) } else { store.update(s) }
                        Task { await store.refreshFX() }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded, let e = editing else { loaded = true; return }; loaded = true
                name = e.name; symbol = e.symbol; currency = e.currency; monthly = e.monthly
                amount = e.perPeriodAmount; accountId = e.accountId
                if let d = e.creditDay { hasCreditDay = true; creditDay = d }
            }
        }
    }
}

// MARK: - Tax profile (track, regime, income, deductions)
struct TaxProfileSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var p = TaxProfile()
    @State private var loaded = false

    private var preview: TaxComputation { TaxEngine.compute(p) }
    private var showSalary: Bool { p.track == .salaried || p.track == .mixed }
    private var showProfessional: Bool { p.track == .selfEmployed || p.track == .mixed }
    private var showBusiness: Bool { p.track == .business || p.track == .mixed }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("I earn as", selection: $p.track) {
                        ForEach(IncomeTrack.allCases) { Text($0.label).tag($0) }
                    }
                    Text(p.track.blurb).font(.caption).foregroundStyle(Zen.ink3)
                } header: { Text("Track") }

                if showSalary {
                    Section("Salary") {
                        LabeledAmountField(label: "Gross annual salary", amount: $p.grossSalary)
                        LabeledAmountField(label: "TDS already deducted", amount: $p.tdsPaid)
                        LabeledAmountField(label: "Employer NPS 80CCD(2)", amount: $p.employerNPS)
                    }
                }
                if showProfessional {
                    Section { LabeledAmountField(label: "Professional receipts (gross)", amount: $p.professionalReceipts) }
                    header: { Text("Profession — 44ADA") }
                    footer: { Text("Presumptive income taxed = 50% of receipts (₹\(INR.compact(p.professionalReceipts * 0.5))).") }
                }
                if showBusiness {
                    Section {
                        LabeledAmountField(label: "Business turnover", amount: $p.businessTurnover)
                        VStack(alignment: .leading) {
                            Text("Digital receipts: \(Int(p.businessDigitalShare * 100))%").font(.caption).foregroundStyle(Zen.ink2)
                            Slider(value: $p.businessDigitalShare, in: 0...1)
                        }
                    } header: { Text("Business — 44AD") }
                    footer: { Text("Presumptive profit = 6% digital + 8% cash (₹\(INR.compact(TaxEngine.presumptive44AD(turnover: p.businessTurnover, digitalShare: p.businessDigitalShare)))).") }
                }

                Section("Other income") {
                    LabeledAmountField(label: "Interest, rent, etc.", amount: $p.otherIncome)
                    LabeledAmountField(label: "Advance tax paid (self)", amount: $p.advanceTaxPaid)
                }

                Section {
                    Toggle("Auto-pick cheaper regime", isOn: $p.autoPickRegime)
                    if !p.autoPickRegime {
                        Picker("Regime", selection: $p.regime) { ForEach(TaxRegime.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented)
                    }
                } header: { Text("Regime") } footer: {
                    Text("Recommended: \(preview.recommended.label) — ₹\(INR.compact((preview.recommended == .new ? preview.newRegime : preview.oldRegime).totalTax)) vs ₹\(INR.compact((preview.recommended == .new ? preview.oldRegime : preview.newRegime).totalTax)).")
                }

                Section {
                    LabeledAmountField(label: "80C (PF, ELSS, LIC…)", amount: $p.ded80C)
                    LabeledAmountField(label: "80D (health insurance)", amount: $p.ded80D)
                    LabeledAmountField(label: "80CCD(1B) NPS", amount: $p.ded80CCD1B)
                    LabeledAmountField(label: "Home-loan interest 24(b)", amount: $p.dedHomeLoanInterest)
                    LabeledAmountField(label: "HRA exemption", amount: $p.dedHRA)
                    LabeledAmountField(label: "Other (80G, 80E…)", amount: $p.otherDeductions)
                } header: { Text("Old-regime deductions") } footer: {
                    Text("Used only in the old-regime estimate (and the comparison). The new regime ignores these except employer NPS.")
                }

                Section {
                    HStack { Text("Estimated tax").foregroundStyle(Zen.ink2); Spacer()
                        Text(INR.compact(preview.totalTax)).fontWeight(.bold).foregroundStyle(Zen.ink) }
                    HStack { Text("Balance after TDS/advance").foregroundStyle(Zen.ink2); Spacer()
                        Text(INR.compact(preview.balanceDue)).fontWeight(.bold).foregroundStyle(Zen.accentDeep) }
                } footer: { Text("Indicative only — not tax advice. FY 2025-26 individual slabs.") }
            }
            .zenForm().navigationTitle("Tax setup").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { p.seeded = true; store.updateTaxProfile(p); dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear { guard !loaded else { return }; loaded = true; p = store.taxProfile }
        }
    }
}

// MARK: - Add / import a payslip
struct AddPayslipSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var slip = Payslip()
    @State private var showPicker = false
    @State private var error: String?
    @State private var imported = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showPicker = true } label: { Label("Import from PDF", systemImage: "doc.badge.plus") }
                    if imported { Label("Read from payslip — check the figures below", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(Zen.greenDeep) }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Zen.caution) }
                } footer: { Text("Best-effort read of common Indian payslip layouts. Anything it misses, fill in below.") }

                Section("Slip") {
                    LabeledField(label: "Employer", placeholder: "Company", text: $slip.employer)
                    DatePicker("Month", selection: $slip.period, displayedComponents: .date)
                }
                Section("Earnings") {
                    LabeledAmountField(label: "Basic", amount: $slip.basic)
                    LabeledAmountField(label: "HRA", amount: $slip.hra)
                    LabeledAmountField(label: "Allowances", amount: $slip.allowances)
                    LabeledAmountField(label: "Gross earnings", amount: $slip.grossEarnings)
                }
                Section("Deductions") {
                    LabeledAmountField(label: "PF (80C)", amount: $slip.pf)
                    LabeledAmountField(label: "Professional tax", amount: $slip.profTax)
                    LabeledAmountField(label: "TDS / income tax", amount: $slip.tds)
                    LabeledAmountField(label: "Net pay", amount: $slip.netPay)
                }
            }
            .zenForm().navigationTitle("Add payslip").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.addPayslip(slip); dismiss() }.fontWeight(.semibold)
                        .disabled(slip.grossEarnings <= 0 && slip.netPay <= 0)
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { result in
                error = nil
                switch result {
                case .success(let url):
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { error = "Couldn't read that file"; return }
                    if let parsed = PayslipParser.parse(data: data) { slip = parsed; imported = true }
                    else { error = "Couldn't read a payslip from that PDF — enter the figures manually." }
                case .failure(let e): error = e.localizedDescription
                }
            }
        }
    }
}

// MARK: - Merchants & learned rules
struct MerchantsView: View {
    @EnvironmentObject var store: Store
    private var rules: [(key: String, cat: String)] {
        store.merchantRules.map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
    }
    var body: some View {
        Form {
            if rules.isEmpty {
                Section { Text("No learned merchants yet. Change a transaction's category and the app will remember it for that merchant.").font(.callout).foregroundStyle(Zen.ink3) }
            }
            ForEach(rules, id: \.key) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.key).font(.subheadline.weight(.semibold)).foregroundStyle(Zen.ink).lineLimit(1)
                        Text(r.cat).font(.caption2).foregroundStyle(Zen.ink3)
                    }
                    Spacer()
                    Menu {
                        ForEach(store.categories.map(\.name), id: \.self) { c in
                            Button(c) { store.learnMerchant(r.key, category: c) }
                        }
                        Divider()
                        Button("Forget", role: .destructive) { store.merchantRules[r.key] = nil; store.save() }
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Zen.accentDeep) }
                }
            }
        }
        .zenForm().navigationTitle("Merchants & rules").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Recurring transfers → planned expenses
struct RecurringView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Form {
            let groups = store.recurringGroups
            if groups.isEmpty {
                Section { Text("No recurring transfers found yet. Once you have a few repeated payments to the same person or account, they'll appear here to link to a budget.").font(.callout).foregroundStyle(Zen.ink3) }
            }
            ForEach(groups) { g in
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink).lineLimit(1)
                            Text("\(g.count)× · \(INR.compact(g.total)) total · last \(g.lastDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(Zen.ink3)
                        }
                        Spacer()
                        if g.linked { Label(g.category, systemImage: "checkmark.circle.fill").font(.caption.weight(.bold)).foregroundStyle(Zen.greenDeep) }
                    }
                    Menu {
                        ForEach(store.categories.map(\.name), id: \.self) { c in
                            Button(c) { store.learnMerchant(g.key, category: c) }
                        }
                    } label: { Label(g.linked ? "Change linked category" : "Link to a budget category", systemImage: "link") }
                }
            }
        }
        .zenForm().navigationTitle("Recurring transfers").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Imported statements ledger (with cascade delete)
struct StatementsView: View {
    @EnvironmentObject var store: Store
    @State private var pendingDelete: StatementRecord?

    private var sorted: [StatementRecord] { store.statements.sorted { $0.importedAt > $1.importedAt } }

    var body: some View {
        Form {
            if store.statements.isEmpty {
                Section { Text("No statements imported yet. Import a PDF/CSV or connect Gmail, and each parsed statement is listed here.").font(.callout).foregroundStyle(Zen.ink3) }
            }
            ForEach(sorted) { s in
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(Zen.accentDeep)
                            Text(s.fileName).font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink).lineLimit(1)
                        }
                        Text("\(s.source) · \(s.importedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(Zen.ink3)
                        if let acc = s.accountName { Text(acc).font(.caption2).foregroundStyle(Zen.ink3) }
                        if let p = s.periodText { Text("Period: \(p)").font(.caption2).foregroundStyle(Zen.ink3) }
                        HStack(spacing: 6) {
                            TagPill(text: "\(s.txnCount) transaction\(s.txnCount == 1 ? "" : "s")")
                            if s.depositCount > 0 { TagPill(text: "\(s.depositCount) deposit\(s.depositCount == 1 ? "" : "s")") }
                        }.padding(.top, 2)
                    }
                    .swipeActions { Button(role: .destructive) { pendingDelete = s } label: { Label("Delete", systemImage: "trash") } }
                }
            }
        }
        .zenForm().navigationTitle("Imported statements").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this statement?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete statement & its \(pendingDelete?.txnCount ?? 0) transaction\((pendingDelete?.txnCount ?? 0) == 1 ? "" : "s")", role: .destructive) {
                if let s = pendingDelete { store.remove(statement: s) }; pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("The transactions ingested from this statement are removed. Reconstructed deposits and manually-edited transactions are kept.") }
    }
}

// MARK: - Conflicts to review (ingestion needs-review queue)
struct ConflictsView: View {
    @EnvironmentObject var store: Store
    @State private var editing: Txn?

    private var open: [DataConflict] { store.unresolvedConflicts.sorted { $0.createdAt > $1.createdAt } }

    var body: some View {
        Form {
            if open.isEmpty {
                Section { Text("Nothing to review. When a statement row is missing a date, amount, or merchant, it's imported with a placeholder and listed here so you can fix it.").font(.callout).foregroundStyle(Zen.ink3) }
            } else {
                Section {
                    Text("These imported transactions need a manual fix. Tap one to correct it.").font(.caption).foregroundStyle(Zen.ink3)
                }
            }
            ForEach(open) { c in
                Section {
                    Button {
                        if let t = store.txn(for: c) { editing = t }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color(hex: "9AA7BE"))
                                Text("Missing \(c.field)").font(.subheadline.weight(.bold)).foregroundStyle(Zen.ink)
                                Spacer()
                                if let t = store.txn(for: c) {
                                    Text((t.income ? "+" : "−") + INR.compact(abs(t.amount))).font(.caption.weight(.bold)).foregroundStyle(Zen.ink2)
                                }
                            }
                            Text(c.reason).font(.caption2).foregroundStyle(Zen.ink2)
                            if let t = store.txn(for: c) {
                                Text("\(t.merchant) · \(t.account) · \(t.date.formatted(.dateTime.day().month().year()))")
                                    .font(.caption2).foregroundStyle(Zen.ink3).lineLimit(1)
                            }
                            if let s = store.statement(for: c) {
                                Label(s.fileName, systemImage: "doc.text").font(.caption2).foregroundStyle(Zen.ink3).lineLimit(1)
                            }
                            if !c.context.isEmpty {
                                Text(c.context).font(.caption2).foregroundStyle(Zen.ink3).lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button { store.resolve(conflict: c) } label: { Label("Dismiss", systemImage: "checkmark") }.tint(Zen.green)
                    }
                }
            }
        }
        .zenForm().navigationTitle("Conflicts").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { LogTxnSheet(editing: $0) }
    }
}
