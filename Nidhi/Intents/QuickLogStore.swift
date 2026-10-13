import Foundation

// Store side of the App-Intents quick log. See Shared/QuickLog.swift for why intents write to a
// shared-container inbox instead of touching `Store`: an intent runs outside the app lifecycle (in
// the background app process for Siri/Shortcuts, in the *widget extension* process for a widget
// button) where `Store`'s `UserDefaults.standard` blob is either absent or unsafe to rewrite.
// Everything below runs on the main thread, inside the app, through the normal mutation path.

extension Store {
    /// Set once we've registered the cross-process listener (static: the app has a single Store).
    private nonisolated(unsafe) static var quickLogWatching = false

    /// Drain pending Siri/Shortcuts/widget entries into `Store`. Call on the main thread only
    /// (`scenePhase == .active` and on the Darwin nudge, which hops to the main queue first).
    func drainQuickLogInbox() {
        startQuickLogWatchIfNeeded()
        let pending = QuickLogInbox.drain()
        guard !pending.isEmpty else { return }
        // Dedupe through the existing externalId path: a drain interrupted between logTxn and the
        // inbox truncation would otherwise re-add the same spend.
        var known = Set(txns.compactMap(\.externalId))
        for e in pending.sorted(by: { $0.date < $1.date }) {
            let ext = "intent:\(e.id.uuidString)"
            guard !known.contains(ext), e.amount > 0 else { continue }
            known.insert(ext)
            let merchant = e.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = merchant.isEmpty ? "Cash spend" : merchant
            let cls = classify(merchant: name, counterparty: nil, narration: name, income: false)
            // An explicitly chosen category wins (matched case-insensitively against real categories);
            // otherwise the merchant goes through the same classifier every other ingest path uses.
            let category = e.category
                .flatMap { c in categories.first { $0.name.caseInsensitiveCompare(c) == .orderedSame }?.name }
                ?? cls.category
            let symbol = categories.first { $0.name == category }?.symbol ?? cls.symbol
            logTxn(Txn(merchant: name, symbol: symbol, category: category, account: "Cash",
                       amount: -abs(e.amount), date: e.date, externalId: ext, source: .unknown))
        }
        // logTxn already ran recomputeSpent() + save(); save() republishes the snapshot, which
        // reconciles the intent's optimistic spent bump with the real figure.
    }

    /// Cross-process nudge so a quick log lands even while the app is already foregrounded
    /// (Siri over the app, or a widget tap on the Home Screen with the app still in memory).
    private func startQuickLogWatchIfNeeded() {
        guard !Self.quickLogWatching else { return }
        Self.quickLogWatching = true
        QuickLogInbox.observe { [weak self] in self?.drainQuickLogInbox() }
    }

    // MARK: snapshot payloads (read by intents + the widget, which can't see Store)

    /// Per-category spend vs cap, normalised to a monthly figure — matches `planTotal`/`spentTotal`.
    var intentCategorySnaps: [NidhiCatSnap] {
        categories.map { NidhiCatSnap(name: $0.name, spent: $0.spent, plan: $0.monthlyPlan, symbol: $0.symbol) }
    }

    /// One-tap widget presets derived from the user's own small spends of the last 90 days
    /// (top 3 categories by frequency, each with its most-used merchant and median amount).
    /// Empty when there isn't enough history — the widget then shows plain amount buttons.
    var intentQuickPresets: [NidhiQuickPreset] {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let small = txns.filter {
            $0.date >= since && $0.amount < 0 && !$0.transfer && abs($0.amount) <= 2_000
            && $0.category != "Transfer" && $0.category != "Income"
        }
        guard small.count >= 3 else { return [] }
        var byCat: [String: [Txn]] = [:]
        for t in small { byCat[t.category, default: []].append(t) }
        return byCat.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .prefix(3).map { cat, list in
            let amounts = list.map { abs($0.amount) }.sorted()
            let median = amounts[amounts.count / 2]
            let rounded = max(10, (median / 10).rounded() * 10)
            var counts: [String: Int] = [:]
            for t in list { counts[t.merchant, default: 0] += 1 }
            let label = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key ?? cat
            let symbol = categories.first { $0.name == cat }?.symbol ?? Store.symbolFor(cat)
            return NidhiQuickPreset(amount: rounded, category: cat, label: label, symbol: symbol)
        }
    }
}

// MARK: - Siri privacy toggle
/// Read intents (budget / safe-to-spend) speak figures aloud and run *without* the app lock, so they
/// are opt-in. Stored as a plain UserDefaults key like the other settings — not part of the `Persist`
/// blob, so nothing in the tolerant-Codable contract changes.
enum SiriPrivacy {
    static let key = "nidhi_siri_read_figures"
    static var allowReadFigures: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
