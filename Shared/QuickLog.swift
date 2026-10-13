import Foundation
import AppIntents
import WidgetKit

// MARK: - Quick log (Siri / Shortcuts / interactive widget)
//
// WHY AN INBOX INSTEAD OF `Store`:
// `Store` is the single source of truth and lives in the app process, backed by one JSON blob in
// `UserDefaults.standard` (NOT an app-group suite — see Persistence.swift). An App Intent runs
// outside the normal app lifecycle: from Siri/Shortcuts it runs in the app's process (possibly
// launched into the background, with no UI and no `Store` instance we can reach), and from a widget
// `Button(intent:)` it runs inside the *widget extension* process, which cannot see
// `UserDefaults.standard` of the app at all. Instantiating a second `Store` there would either read
// nothing or — worse — write a stale blob back and clobber user data.
//
// So an intent never touches `Store`. It appends an immutable entry to a small JSON **inbox** in the
// shared App Group container (`NSFileCoordinator`-coordinated, so two processes can't interleave a
// read-modify-write), and the app drains that inbox into `Store` on the main thread when it next
// becomes active (`Store.drainQuickLogInbox()`), going through the normal `logTxn` → `recomputeSpent`
// → `save()` path. That makes the write actually persisted, keeps every mutation on one thread, and
// means the intent can never race the UI.
//
// Exactly-once: each entry carries a UUID and lands as `externalId = "intent:<uuid>"`, so even if a
// drain is interrupted after `logTxn` but before the inbox truncation, the existing externalId dedupe
// drops the repeat.

// MARK: Entry (the DTO written by intents, read by the app)
struct QuickLogEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var amount: Double        // always a positive magnitude; the app stores it as a spend (negative)
    var merchant: String      // may be empty ("log 250")
    var category: String?     // user-picked category name, nil → the app classifies from the merchant
    var date: Date

    init(id: UUID = UUID(), amount: Double, merchant: String = "", category: String? = nil, date: Date = Date()) {
        self.id = id; self.amount = amount; self.merchant = merchant; self.category = category; self.date = date
    }

    // Tolerant decode (same rule as Persistence.swift): a malformed/older entry must never throw and
    // take the whole inbox down with it.
    enum CodingKeys: String, CodingKey { case id, amount, merchant, category, date }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? 0
        merchant = (try? c.decodeIfPresent(String.self, forKey: .merchant)) ?? ""
        category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? nil
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
    }
}

// MARK: Inbox (shared container, cross-process safe)
enum QuickLogInbox {
    static var url: URL { NidhiShared.containerURL.appendingPathComponent("quicklog_inbox.json") }

    /// Serialises appends/drains happening on several threads *within* one process; NSFileCoordinator
    /// handles the app ↔ widget-extension case.
    private static let lock = NSLock()

    static func append(_ entry: QuickLogEntry) {
        mutate { $0.append(entry) }
        notifyApp()
    }

    /// Returns everything pending and empties the inbox in the same coordinated write.
    @discardableResult
    static func drain() -> [QuickLogEntry] {
        var out: [QuickLogEntry] = []
        mutate { list in out = list; list = [] }
        return out
    }

    static var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return read(url).count
    }

    private static func mutate(_ body: (inout [QuickLogEntry]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var err: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &err) { u in
            var list = read(u)
            body(&list)
            if list.isEmpty {
                try? FileManager.default.removeItem(at: u)
            } else if let d = try? JSONEncoder().encode(list) {
                try? d.write(to: u, options: .atomic)
            }
        }
    }

    private static func read(_ u: URL) -> [QuickLogEntry] {
        guard let d = try? Data(contentsOf: u),
              let list = try? JSONDecoder().decode([QuickLogEntry].self, from: d) else { return [] }
        return list
    }

    // MARK: cross-process nudge
    // Darwin notifications are the only cross-process signal available to an iOS app extension.
    // It's an optimisation, not the contract: if the app isn't running the drain still happens on
    // the next `scenePhase == .active`.
    static let darwinName = "com.suhail.Nidhi.quicklog" as CFString

    static func notifyApp() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(darwinName), nil, nil, true)
    }

    private nonisolated(unsafe) static var handler: (() -> Void)?

    /// App side: run `body` (on the main queue) whenever an intent appends from another process.
    static func observe(_ body: @escaping () -> Void) {
        handler = body
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { QuickLogInbox.handler?() }
        }, darwinName, nil, .deliverImmediately)
    }
}

// MARK: - Snapshot pieces the intents/widget read (written by the app on every save)
struct NidhiCatSnap: Codable, Hashable, Sendable {
    var name: String
    var spent: Double
    var plan: Double          // normalised to a per-month figure
    var symbol: String
}

struct NidhiQuickPreset: Codable, Hashable, Identifiable, Sendable {
    var amount: Double
    var category: String
    var label: String         // merchant/label used for the logged txn
    var symbol: String
    var id: String { "\(label)-\(category)-\(amount)" }

    /// Shown before there's enough history to derive real presets. Amounts only — no fabricated figures.
    static let defaults: [NidhiQuickPreset] = [
        NidhiQuickPreset(amount: 100, category: "", label: "Cash spend", symbol: "indianrupeesign.circle"),
        NidhiQuickPreset(amount: 250, category: "", label: "Cash spend", symbol: "indianrupeesign.circle"),
        NidhiQuickPreset(amount: 500, category: "", label: "Cash spend", symbol: "indianrupeesign.circle"),
    ]
}

extension NidhiSnapshot {
    // Tolerant decode: `cats`/`quickPresets` were added after the first snapshots shipped, and the
    // synthesised Codable init throws on a missing key even for properties with defaults. Without
    // this every widget would fall back to `.placeholder` until the app next saved.
    enum CodingKeys: String, CodingKey {
        case netWorth, netWorthChange, spent, plan, targetPct, topGoalTitle, topGoalSaved, topGoalTarget
        case streakMonths, nwHistory, updated, cats, quickPresets
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        netWorth = d(.netWorth, 0); netWorthChange = d(.netWorthChange, 0)
        spent = d(.spent, 0); plan = d(.plan, 0)
        targetPct = d(.targetPct, 0)
        topGoalTitle = d(.topGoalTitle, "No goal yet")
        topGoalSaved = d(.topGoalSaved, 0); topGoalTarget = d(.topGoalTarget, 1)
        streakMonths = d(.streakMonths, 0)
        nwHistory = d(.nwHistory, [])
        updated = d(.updated, Date(timeIntervalSince1970: 0))
        cats = d(.cats, [])
        quickPresets = d(.quickPresets, [])
    }

    /// True once the app has written a real snapshot (never show/derive figures before that).
    var hasRealData: Bool { updated > Date(timeIntervalSince1970: 0) }

    /// Optimistic bump so an interactive-widget tap moves the budget bar immediately. The app
    /// reconciles the true figure on its next `save()` (drain → recomputeSpent → publishSnapshot).
    static func applyOptimisticSpend(_ amount: Double, category: String?) {
        var s = NidhiSnapshot.load()
        guard s.hasRealData else { return }
        s.spent += amount
        if let c = category, let i = s.cats.firstIndex(where: { $0.name.caseInsensitiveCompare(c) == .orderedSame }) {
            s.cats[i].spent += amount
        }
        s.save()
    }
}

// MARK: - Formatting
enum QuickLogFormat {
    /// Exact ₹ with Indian digit grouping — confirmations must not round the way `NidhiShared.inr` does.
    static func rupees(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = v == v.rounded() ? 0 : 2
        return "₹" + (f.string(from: NSNumber(value: v)) ?? String(Int(v)))
    }
}

// MARK: - Category options (dynamic, from the snapshot)
// An `AppEnum` is compiled statically, so a renamed/added category would silently vanish from Siri.
// A String parameter + DynamicOptionsProvider reading the shared snapshot always matches the app.
struct QuickLogCategoryOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        let names = NidhiSnapshot.load().cats.map(\.name)
        return names.isEmpty ? ["Food", "Transport", "Shopping", "Bills", "Health", "Other"] : names
    }
}

// MARK: - Log a spend (Siri, Shortcuts, Spotlight, widget button)
struct LogTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Transaction"
    static var description: IntentDescription {
        IntentDescription("Log a cash or UPI spend. It's added to Nidhi the next time you open the app.",
                          categoryName: "Logging",
                          searchKeywords: ["spend", "expense", "cash", "log", "transaction"])
    }
    /// Runs entirely in the background — the whole point is not having to open the app.
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Amount", description: "Amount spent, in rupees.",
               requestValueDialog: "How much did you spend?")
    var amount: Double

    @Parameter(title: "Merchant", description: "Who you paid.",
               requestValueDialog: "What was it for?")
    var merchant: String?

    @Parameter(title: "Category", description: "Budget category.",
               optionsProvider: QuickLogCategoryOptions())
    var category: String?

    init() {}
    init(amount: Double, merchant: String? = nil, category: String? = nil) {
        self.amount = amount
        self.merchant = merchant
        self.category = (category?.isEmpty ?? true) ? nil : category
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) spent at \(\.$merchant)") {
            \.$category
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let amt = abs(amount)
        guard amt > 0 else { throw $amount.needsValueError("How much did you spend?") }
        let name = (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        QuickLogInbox.append(QuickLogEntry(amount: amt, merchant: name,
                                           category: (cat?.isEmpty ?? true) ? nil : cat))
        NidhiSnapshot.applyOptimisticSpend(amt, category: cat)
        WidgetCenter.shared.reloadAllTimelines()

        var where_ = ""
        if !name.isEmpty { where_ = " at \(name)" }
        else if let c = cat, !c.isEmpty { where_ = " under \(c)" }
        return .result(dialog: IntentDialog(stringLiteral: "Logged \(QuickLogFormat.rupees(amt))\(where_)."))
    }
}
