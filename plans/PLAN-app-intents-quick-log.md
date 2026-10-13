# PLAN: App Intents — Siri quick-log, Shortcuts & interactive widget

**Missing-feature rank: 9 of 10.** Cash and small UPI spends die unlogged because logging means:
unlock → app → tab → sheet → 5 fields. "Hey Siri, log 250 for coffee" / a lock-screen widget button
removes the friction that most hurts data completeness (cash never appears in any statement or email).

## Goal

App Intents: `LogTransactionIntent(amount, merchant?, category?)`, `CheckBudgetIntent(category?)`,
`SafeToSpendIntent` (if PLAN-cashflow-forecast landed) — exposed to Siri/Shortcuts/Spotlight, plus a
small interactive widget with 2-3 one-tap quick-log buttons for the user's most frequent cash spends.

## Files to touch

- **Create** `Nidhi/AppIntents.swift` — intents + `AppShortcutsProvider` (phrases: "Log ₹ in
  <app name>", "How's my budget in <app name>").
- [Nidhi/State/Store.swift](Nidhi/State/Store.swift) / `Shared/` — intents run in extension processes
  too; check how `NidhiShared` (widget snapshot) is structured under `Shared/`. Writing a txn from an
  extension needs an **inbox** pattern: intents append to a shared-container JSON inbox; the app
  drains it into `Store` on foreground/background refresh. Do NOT try to instantiate `Store` (whole
  UserDefaults blob) inside the intent unless UserDefaults is already app-group-shared — check
  `Persistence.swift` for the suite used; if it's `.standard`, the inbox is mandatory.
- [NidhiWidgets/NidhiWidgets.swift](NidhiWidgets/NidhiWidgets.swift) — a
  `QuickLogWidget` with `Button(intent:)` rows (amount presets per top cash categories).
- `Nidhi/App/NidhiApp.swift` — drain the inbox on `scenePhase == .active`.
- Entitlements — an App Group for the shared container (both targets). **Gotcha:** free personal team —
  App Groups DO work on free teams (unlike iCloud); still verify `-allowProvisioningUpdates` succeeds.

## Implementation order

1. Establish the app group + shared inbox file (`group.com.suhail.Nidhi/inbox.json`, an array of
   pending txn DTOs, appended atomically with `NSFileCoordinator`).
2. `LogTransactionIntent`: parameters amount (required), merchant (string, optional), category (an
   `AppEnum` built from the *default* category list — extensions can't read live Store categories
   unless the snapshot exposes them; add category names to the `NidhiShared` snapshot so the enum/
   suggestions stay current).
3. Drain-on-active in the app: run through `Store.classify` when merchant given, else the chosen
   category; source = manual; then `recomputeSpent()`.
4. Budget/safe-to-spend read intents: answer from the `NidhiShared` snapshot (already refreshed by the
   app) — read-only, no Store needed. Return a spoken + visual snippet.
5. `AppShortcutsProvider` phrases, then the interactive widget (iOS 17+ `Button(intent:)`).
6. Test: Shortcuts app first (deterministic), then Siri voice, then widget taps; verify a quick-logged
   txn appears with correct category and the budget bar moves after opening the app.

## Edge cases a weaker model would miss

- **Two sources of truth**: the inbox must be drained exactly once — mark entries with UUIDs; the txn
  gets `externalId = "intent:<uuid>"` so double-drains dedupe through the existing externalId path.
- Widget timeline shows stale budget after a quick log — call `WidgetCenter.reloadAllTimelines()` from
  the intent after appending, and have the *intent* optimistically bump the snapshot's spent figure so
  the widget reflects the tap immediately (the app reconciles later).
- Siri may pass amounts as "two fifty" → `Double` handled by the framework, but currency phrasing
  ("250 rupees") needs the parameter declared as `Double` not `Measurement` for reliability.
- `AppEnum` categories are compiled static — dynamic options need `DynamicOptionsProvider` reading the
  snapshot; do that, or renamed categories silently vanish from Siri.
- Intents run without the app lock (PLAN-app-lock) — read intents expose budget figures; gate
  `SafeToSpendIntent`/`CheckBudgetIntent` behind a Settings toggle "Allow Siri to read figures".

## Acceptance criteria

- [ ] Shortcuts: "Log Transaction" with amount+category creates exactly one txn after app open, even
      if the shortcut ran twice while the app was closed (dedupe proven).
- [ ] Siri phrase works end-to-end on device/simulator.
- [ ] Widget quick-log button logs and the widget's budget bar updates without opening the app.
- [ ] Read intents honour the privacy toggle.
- [ ] Both targets build green with the App Group entitlement on the free team.
