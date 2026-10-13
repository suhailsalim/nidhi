# Siri, Shortcuts & the quick-log widget (App Intents)

Cash and small UPI spends never appear in a statement or an email, so they only get tracked if
logging is nearly free. Three App Intents + one interactive widget make that possible without
opening the app.

| Intent | Type | Answer / effect |
|--------|------|-----------------|
| `LogTransactionIntent` ("Log Transaction") | write | Queues a spend (amount, optional merchant, optional category) |
| `CheckBudgetIntent` ("Check Budget") | read | Month or single-category spend vs cap |
| `SafeToSpendIntent` ("Safe To Spend") | read | What's left of the monthly plan and roughly per day |

Siri phrases live in `NidhiShortcuts: AppShortcutsProvider` (e.g. "Log a spend in Nidhi",
"How's my budget in Nidhi", "What's safe to spend in Nidhi").

## Why intents never touch `Store`

`Store` is the single source of truth and its blob lives in **`UserDefaults.standard`** of the app
(see [persistence-and-backup.md](persistence-and-backup.md)) — not an app-group suite. An App Intent
runs outside the normal app lifecycle:

- from Siri/Shortcuts/Spotlight it runs in the app process, possibly launched into the background
  with no `Store` instance to reach;
- from a widget `Button(intent:)` it runs in the **widget-extension** process, which cannot see the
  app's `UserDefaults.standard` at all.

Creating a second `Store` there would read nothing and could write a stale blob back over real data.

## The inbox

`LogTransactionIntent` therefore appends a `QuickLogEntry` (uuid, amount, merchant, category, date)
to `quicklog_inbox.json` in the App Group container (`group.com.suhail.Nidhi`), guarded by
`NSFileCoordinator` so the app and the extension can't interleave a read-modify-write.

`Store.drainQuickLogInbox()` (called on `scenePhase == .active`, and on a Darwin notification when
the app is already foregrounded) drains it on the main thread and pushes each entry through the
normal `logTxn` → `classify` → `recomputeSpent` → `save()` path. Account is `Cash`; an explicitly
chosen category wins, otherwise the merchant goes through the usual classifier.

**Exactly once:** each entry lands with `externalId = "intent:<uuid>"`, so a drain interrupted
between `logTxn` and the inbox truncation — or a shortcut that ran twice while the app was closed —
dedupes through the existing externalId guard.

## Snapshot fields

`NidhiSnapshot` (written on every `Store.save()`) carries two extra payloads for code that can't see
`Store`:

- `cats` — per-category name/spent/plan/symbol: powers `CheckBudgetIntent` and the **dynamic**
  category options (`QuickLogCategoryOptions: DynamicOptionsProvider`). A static `AppEnum` would make
  renamed categories silently vanish from Siri.
- `quickPresets` — up to three one-tap buttons derived from the user's own small spends of the last
  90 days (top categories, most-used merchant, median amount). Empty until there's real history; the
  widget then shows plain ₹100/₹250/₹500 buttons.

Both decode tolerantly (`Shared/QuickLog.swift`), so a snapshot written by an older build still loads
instead of falling back to the placeholder.

## Widget

`QuickLogWidget` (small/medium) shows the budget bar plus preset buttons. The intent optimistically
bumps the snapshot's `spent` and calls `WidgetCenter.reloadAllTimelines()`, so the bar moves on the
tap; the app reconciles the true figure when it next drains and saves.

## Privacy

Read intents are **off by default** — Siri answers before the Face ID app lock, so anyone holding the
phone could otherwise hear balances. Settings → *Siri & Shortcuts* → "Let Siri read my figures"
(`nidhi_siri_read_figures` in `UserDefaults`, not part of the persisted blob). Logging a spend is
always allowed; it reveals nothing.

## Files

- `Shared/QuickLog.swift` — inbox, DTO, `LogTransactionIntent`, dynamic options, snapshot decode
  (compiled into **both** targets; it's the only intent the widget needs).
- `Nidhi/Intents/AppIntents.swift` — read intents, snippet view, `AppShortcutsProvider`,
  Settings section.
- `Nidhi/Intents/QuickLogStore.swift` — `Store.drainQuickLogInbox()`, snapshot payloads,
  `SiriPrivacy`.
- `NidhiWidgets/QuickLogWidget.swift` — the interactive widget.
