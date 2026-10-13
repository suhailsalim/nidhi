import Foundation
import ActivityKit

// Shared between the app and the widget/Live-Activity extension.

enum NidhiShared {
    static let appGroup = "group.com.suhail.Nidhi"
    static let snapshotKey = "nidhi_snapshot_v1"

    /// File-based shared storage. Uses the App Group container when available (so the widget
    /// can read it) and falls back to the app's Documents dir otherwise. Avoids
    /// `UserDefaults(suiteName:)`, which logs a CFPrefs "AnyUser with a container" warning.
    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var snapshotURL: URL { containerURL.appendingPathComponent("\(snapshotKey).json") }

    /// Compact Indian currency (₹12.4L, ₹1.2Cr, ₹8.5k) — usable from the widget too.
    static func inr(_ v: Double) -> String {
        let sign = v < 0 ? "-" : ""
        let n = abs(v)
        func t(_ x: Double) -> String {
            let r = (x*10).rounded()/10
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
        }
        if n >= 10_000_000 { return "\(sign)₹\(t(n/10_000_000))Cr" }
        if n >= 100_000    { return "\(sign)₹\(t(n/100_000))L" }
        if n >= 1_000      { return "\(sign)₹\(t(n/1_000))k" }
        return "\(sign)₹\(Int(n))"
    }
}

/// Snapshot the app writes to the App Group on every save; widgets read it.
struct NidhiSnapshot: Codable {
    var netWorth: Double
    var netWorthChange: Double
    var spent: Double
    var plan: Double
    var targetPct: Int            // progress toward the ₹50L milestone
    var topGoalTitle: String
    var topGoalSaved: Double
    var topGoalTarget: Double
    var streakMonths: Int
    var nwHistory: [Double]
    var updated: Date
    // Added for App Intents (Siri / Shortcuts / interactive widget). Decoded tolerantly in
    // QuickLog.swift so a snapshot written by an older build still loads.
    var cats: [NidhiCatSnap] = []            // per-category spend vs cap, for CheckBudgetIntent + Siri options
    var quickPresets: [NidhiQuickPreset] = [] // widget one-tap buttons, derived from real cash spends

    var planPct: Double { plan > 0 ? min(1, spent/plan) : 0 }
    var goalPct: Double { topGoalTarget > 0 ? min(1, topGoalSaved/topGoalTarget) : 0 }

    /// Empty placeholder — never show fabricated figures (used before any real data exists).
    static let placeholder = NidhiSnapshot(
        netWorth: 0, netWorthChange: 0, spent: 0, plan: 0,
        targetPct: 0, topGoalTitle: "No goal yet", topGoalSaved: 0, topGoalTarget: 1,
        streakMonths: 0, nwHistory: [], updated: Date(timeIntervalSince1970: 0))

    static func load() -> NidhiSnapshot {
        guard let d = try? Data(contentsOf: NidhiShared.snapshotURL),
              let s = try? JSONDecoder().decode(NidhiSnapshot.self, from: d) else { return .placeholder }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: NidhiShared.snapshotURL, options: .atomic) }
    }
}

/// Live Activity: a calm monthly-budget tracker on the Lock Screen / Dynamic Island.
struct BudgetActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var spent: Double
        var plan: Double
        var daysLeft: Int
        var pct: Double { plan > 0 ? min(1, spent/plan) : 0 }
    }
    var month: String
}
