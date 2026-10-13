import Foundation

// MARK: - AI insight tasks
//
// Builds an aggregate-only summary of the user's finances (never raw transactions, account numbers,
// or merchant-level rows) and turns it into prompts. What leaves the device is the summary below.

enum AIInsightKind: String, CaseIterable, Identifiable {
    case spending, budget, goal, savings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spending: return "Analyse my spending"
        case .budget: return "Review my budget"
        case .goal: return "Suggest a goal"
        case .savings: return "Where can I save?"
        }
    }
    var symbol: String {
        switch self {
        case .spending: return "chart.bar.xaxis"
        case .budget: return "checklist"
        case .goal: return "target"
        case .savings: return "scissors"
        }
    }
    var prompt: String {
        switch self {
        case .spending: return "Analyse my spending patterns. Call out the biggest categories, anything unusual or trending up, and 2-3 concrete observations. Be specific with the numbers I gave you."
        case .budget: return "Review my budget. Which categories am I over or close to the limit on, which caps look too high or too low, and what should I adjust? Keep it practical."
        case .goal: return "Suggest one realistic savings goal for me given my net worth, monthly surplus and existing goals. Give a target amount, a monthly contribution and a timeframe, and explain why it fits."
        case .savings: return "Find where I could realistically cut spending without much pain. Prioritise recurring/subscription spend and categories that are high vs my income. Give specifics."
        }
    }
}

enum AIInsights {
    static let system = """
    You are a careful personal-finance assistant inside an India-focused budgeting app (amounts are INR, ₹).
    You are given an aggregate snapshot of the user's finances. Be concrete, use the actual numbers, and
    keep advice practical and India-relevant. Use short markdown with bold headers and tight bullets. Do
    not invent data you weren't given. You are not a registered adviser — add a one-line caveat only if you
    give tax or investment specifics.
    """

    /// Aggregate-only snapshot. No raw transactions, no account/card numbers, no individual merchant rows.
    static func summary(_ store: Store) -> String {
        var L: [String] = []
        func inr(_ v: Double) -> String { "₹\(Int(v))" }

        L.append("# Snapshot (\(store.financialYearLabel))")
        L.append("Liquid net worth: \(inr(store.liquidNetWorth)) (banks \(inr(store.banksTotal)), deposits \(inr(store.depositsTotal)), investments \(inr(store.investmentsTotal)), card dues \(inr(store.cardsTotal)))")
        L.append("Net-worth target: \(inr(store.netWorthTarget)) (\(store.toTargetPct)% there)")

        // Income & tax
        let monthlyIncome = store.grossIncome / 12
        L.append("\n## Income & tax")
        L.append("Annual income ≈ \(inr(store.grossIncome)) (~\(inr(monthlyIncome))/mo). Track: \(store.taxProfile.track.label).")
        if store.taxTotal > 0 {
            L.append("Estimated tax \(inr(store.taxTotal)) on the \(store.tax.selected.label); recommended regime: \(store.tax.recommended.label).")
        }

        // This-month budget
        L.append("\n## This month")
        L.append("Spent \(inr(store.spentTotal)) of \(inr(store.planTotal)) planned (\(store.planPct)%), \(store.daysLeftInMonth) days left.")

        // Categories (cap period aware)
        let cats = store.categories.filter { $0.plan > 0 || $0.spent > 0 }.sorted { $0.spent > $1.spent }.prefix(12)
        if !cats.isEmpty {
            L.append("\n## Categories (spent / cap, per cycle)")
            for c in cats {
                let per = c.period == .monthly ? "" : " [\(c.period.label.lowercased())]"
                L.append("- \(c.name)\(per): \(inr(c.spent)) / \(inr(c.plan))\(c.over ? " — OVER" : "")")
            }
        }

        // Top tags & recurring (3 months)
        let tags = store.spendByTag(months: 3).prefix(6)
        if !tags.isEmpty {
            L.append("\n## Top spend tags (3 mo)")
            for t in tags { L.append("- \(t.tag): \(inr(t.amount))") }
        }
        let recurring = store.recurringGroups.prefix(8)
        if !recurring.isEmpty {
            L.append("\n## Recurring payments")
            for r in recurring { L.append("- \(r.name): \(r.count)× totalling \(inr(r.total)) (\(r.category))") }
        }

        // Goals
        if !store.goals.isEmpty {
            L.append("\n## Goals")
            for g in store.goals.prefix(8) {
                L.append("- \(g.title): \(inr(g.saved))/\(inr(g.target)) by \(g.deadlineText), \(g.status.rawValue), \(inr(g.monthly))/mo")
            }
        }
        return L.joined(separator: "\n")
    }

    static func userPrompt(_ kind: AIInsightKind, store: Store) -> String {
        "\(kind.prompt)\n\nHere is my financial snapshot:\n\n\(summary(store))"
    }
}
