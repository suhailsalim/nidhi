import AppIntents
import SwiftUI

// App-target App Intents: the two *read* intents (answered entirely from the shared snapshot the app
// publishes on every save — no `Store` instance needed, nothing to persist) plus the Siri phrases.
// The *write* intent lives in Shared/QuickLog.swift because the widget extension needs it too.

// MARK: - Snippet view (shared by both read intents)
struct BudgetSnippetView: View {
    let title: String
    let detail: String
    let pct: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(Zen.ink)
            if let pct {
                ProgressView(value: min(1, max(0, pct)))
                    .tint(pct > 1 ? Zen.caution : Zen.accentDeep)
            }
            Text(detail).font(.subheadline).foregroundStyle(Zen.ink2)
        }
        .padding()
    }
}

private let privacyOffLine = "Turn on “Let Siri read my figures” in Nidhi → Settings to hear budget numbers."

// MARK: - How's my budget?
struct CheckBudgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Budget"
    static var description: IntentDescription {
        IntentDescription("Hear how this month's spending compares with your plan.",
                          categoryName: "Insights",
                          searchKeywords: ["budget", "spend", "plan", "left"])
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Category", description: "Ask about one category instead of the whole month.",
               optionsProvider: QuickLogCategoryOptions())
    var category: String?

    init() {}
    init(category: String? = nil) { self.category = category }

    static var parameterSummary: some ParameterSummary {
        Summary("Check my budget for \(\.$category)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard SiriPrivacy.allowReadFigures else {
            return .result(dialog: IntentDialog(stringLiteral: privacyOffLine),
                           view: BudgetSnippetView(title: "Figures are private", detail: privacyOffLine, pct: nil))
        }
        let snap = NidhiSnapshot.load()
        guard snap.hasRealData else {
            let line = "There's nothing tracked yet."
            return .result(dialog: IntentDialog(stringLiteral: line),
                           view: BudgetSnippetView(title: "Nidhi", detail: line, pct: nil))
        }
        if let name = category?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            guard let c = snap.cats.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                let line = "I couldn't find a category called \(name)."
                return .result(dialog: IntentDialog(stringLiteral: line),
                               view: BudgetSnippetView(title: name, detail: line, pct: nil))
            }
            let left = c.plan - c.spent
            let line = c.plan <= 0
                ? "\(c.name): \(QuickLogFormat.rupees(c.spent)) spent this month, no cap set."
                : (left >= 0
                   ? "\(c.name): \(QuickLogFormat.rupees(c.spent)) of \(QuickLogFormat.rupees(c.plan)) — \(QuickLogFormat.rupees(left)) left."
                   : "\(c.name): \(QuickLogFormat.rupees(c.spent)) of \(QuickLogFormat.rupees(c.plan)) — over by \(QuickLogFormat.rupees(-left)).")
            return .result(dialog: IntentDialog(stringLiteral: line),
                           view: BudgetSnippetView(title: c.name, detail: line,
                                                   pct: c.plan > 0 ? c.spent / c.plan : nil))
        }
        let left = snap.plan - snap.spent
        let line = snap.plan <= 0
            ? "You've spent \(QuickLogFormat.rupees(snap.spent)) this month. No monthly plan set yet."
            : (left >= 0
               ? "You've spent \(QuickLogFormat.rupees(snap.spent)) of \(QuickLogFormat.rupees(snap.plan)) — \(QuickLogFormat.rupees(left)) left this month."
               : "You've spent \(QuickLogFormat.rupees(snap.spent)) of \(QuickLogFormat.rupees(snap.plan)) — over plan by \(QuickLogFormat.rupees(-left)).")
        return .result(dialog: IntentDialog(stringLiteral: line),
                       view: BudgetSnippetView(title: "This month", detail: line,
                                               pct: snap.plan > 0 ? snap.planPct : nil))
    }
}

// MARK: - What's safe to spend?
struct SafeToSpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Safe To Spend"
    static var description: IntentDescription {
        IntentDescription("What's left of this month's plan, and roughly how much a day that is.",
                          categoryName: "Insights",
                          searchKeywords: ["safe", "spend", "left", "daily"])
    }
    static var openAppWhenRun: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard SiriPrivacy.allowReadFigures else {
            return .result(dialog: IntentDialog(stringLiteral: privacyOffLine),
                           view: BudgetSnippetView(title: "Figures are private", detail: privacyOffLine, pct: nil))
        }
        let snap = NidhiSnapshot.load()
        guard snap.hasRealData, snap.plan > 0 else {
            let line = "Set a monthly plan first — then I can tell you what's safe to spend."
            return .result(dialog: IntentDialog(stringLiteral: line),
                           view: BudgetSnippetView(title: "Safe to spend", detail: line, pct: nil))
        }
        let cal = Calendar.current, now = Date()
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let daysLeft = max(1, daysInMonth - cal.component(.day, from: now) + 1)
        let left = max(0, snap.plan - snap.spent)
        let perDay = left / Double(daysLeft)
        let line = left > 0
            ? "\(QuickLogFormat.rupees(left)) left for \(daysLeft) more \(daysLeft == 1 ? "day" : "days") — about \(QuickLogFormat.rupees(perDay.rounded())) a day."
            : "You're already over this month's plan by \(QuickLogFormat.rupees(snap.spent - snap.plan))."
        return .result(dialog: IntentDialog(stringLiteral: line),
                       view: BudgetSnippetView(title: "Safe to spend", detail: line, pct: snap.planPct))
    }
}

// MARK: - Siri phrases (Shortcuts / Spotlight / voice)
struct NidhiShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogTransactionIntent(),
                    phrases: ["Log a spend in \(.applicationName)",
                              "Log an expense in \(.applicationName)",
                              "Log rupees in \(.applicationName)",
                              "Add a transaction to \(.applicationName)"],
                    shortTitle: "Log spend",
                    systemImageName: "indianrupeesign.circle")
        AppShortcut(intent: CheckBudgetIntent(),
                    phrases: ["How's my budget in \(.applicationName)",
                              "Check my budget in \(.applicationName)",
                              "How much have I spent in \(.applicationName)"],
                    shortTitle: "Check budget",
                    systemImageName: "chart.pie")
        AppShortcut(intent: SafeToSpendIntent(),
                    phrases: ["What's safe to spend in \(.applicationName)",
                              "How much can I spend in \(.applicationName)"],
                    shortTitle: "Safe to spend",
                    systemImageName: "leaf")
    }
}

// MARK: - Settings row (inserted into SettingsView's List)
struct SiriSettingsSection: View {
    @EnvironmentObject var store: Store
    @AppStorage(SiriPrivacy.key) private var allowFigures = false
    var body: some View {
        Section {
            Toggle(isOn: $allowFigures) { Label("Let Siri read my figures", systemImage: "waveform") }
                .onChange(of: allowFigures) { _, _ in store.publishSnapshot() }
        } header: { Text("Siri & Shortcuts") } footer: {
            Text("Say “Log a spend in Nidhi” to add a cash spend without opening the app — it lands the next time you open it. Budget answers stay off by default: Siri runs before the app lock, so anyone holding your phone could otherwise hear your numbers.")
        }
    }
}
