# PLAN: Surface pending locked statements (stop silent data gaps)

**Rank: 3 of 5.** When Gmail auto-import finds a password-locked statement PDF that no vaulted password
opens, it parks in `GmailManager.pending` and waits — visible ONLY under Settings → "Needs password"
([Sheets.swift:1016](Nidhi/UI/Sheets.swift:1016) area). Real consequence already observed (memory +
buglog): the Federal Bank account was never created because its locked statements sat pending unnoticed.
Every downstream number (net worth, balances, Plan actuals) is silently wrong until the user stumbles
into Settings. Small UI change, large data-completeness payoff.

## Goal

Pending statements become impossible to miss: a badge/banner on the Home and Accounts screens that
deep-links to the password entry, and a local notification when a new pending item appears.

## Files to touch

- [Nidhi/Gmail/GmailManager.swift](Nidhi/Gmail/GmailManager.swift) — `pending` is `@Published` (~line
  30); `addPending` (~line 117 call site) is where a new pending item is born → notification hook here.
- [Nidhi/UI/HomeView.swift](Nidhi/UI/HomeView.swift) — banner card.
- [Nidhi/UI/AccountsView.swift](Nidhi/UI/AccountsView.swift) — banner/row.
- [Nidhi/UI/Sheets.swift](Nidhi/UI/Sheets.swift) — the existing "Needs password" UI (~1016);
  extract or expose it so it can be presented as a sheet from Home/Accounts (reuse, don't duplicate).
- [Nidhi/Platform/Notifications.swift](Nidhi/Platform/Notifications.swift) — one new local-notification helper,
  following the existing pattern (check `setEnabled` gating).
- [Nidhi/UI/Components.swift](Nidhi/UI/Components.swift) — only if a suitable banner component
  doesn't already exist; check first (the design-system rule: reuse `Components.swift`).

## Implementation order

1. Read the existing "Needs password" section in Sheets.swift (~1016) and the `PendingStatement` model
   (`StatementVault.swift:27`). Extract the pending-list + password-entry UI into a reusable view (e.g.
   `PendingStatementsSheet`) that Settings keeps using — behaviour identical.
2. Home banner: in HomeView, when `gmail.pending` is non-empty, show a tappable warning card
   ("2 statements need a password — accounts may be missing transactions") styled with the `Zen`
   palette/`Theme.swift` warning tone, presenting `PendingStatementsSheet`. `GmailManager` — check how
   HomeView currently accesses it (EnvironmentObject vs singleton) and use the same mechanism.
3. Accounts banner: same card at the top of AccountsView's list.
4. Notification: in the code path that appends a *new* pending item (`addPending`), if the item wasn't
   already pending (the dedupe at GmailManager.swift:104 already guards re-adds), post one local
   notification via Notifications.swift: "A locked statement needs its password". Respect the app's
   notifications toggle; never notify on app-launch rehydration of the persisted pending list (only on
   genuinely new appends during a scan).
5. Build + verify in simulator: with a pending item present (fabricate one by importing a locked fixture
   PDF without its password, or temporarily seed `pending`), banner shows on Home + Accounts, tap opens
   the sheet, entering the correct password imports and clears banner everywhere.

## Edge cases a weaker model would miss

- **`.unlockedButEmpty` vs `.needsPassword`** (GmailManager.swift:127-145, bug-019): a PDF that *opens*
  but yields nothing is NOT queued as pending — don't change that classification, and don't count such
  items in the badge.
- **`importPending` return semantics** (GmailManager.swift:152): nil = success; `.wrongPassword`/
  `.locked` keep the item queued for retry; `.noTransactions` marks processed and removes it. The
  extracted sheet must preserve all three outcomes and their user feedback.
- Successful password entry is **vaulted** (`StatementVault`) so future statements auto-unlock — the
  extracted UI must keep whatever vault-save call the Settings version makes.
- The pending list is persisted (`gmail_pending_stmts`) and rehydrated at init (GmailManager.swift:30
  with `dedupe`) — the notification hook must NOT fire during that rehydration path.
- "Clear all data" resets pending (GmailManager.swift:58-70) — the banner must react (it will, if it
  reads the `@Published pending` directly; don't cache counts).
- Notifications require permission; `Notifications.setEnabled` handles authorization — call through it,
  don't call `UNUserNotificationCenter` raw.
- Don't put the count in the tab badge via `Store` — `pending` lives on `GmailManager`, keep it there
  (single source of truth per domain).

## Acceptance criteria

- [ ] With ≥1 pending statement: warning banner visible on Home AND Accounts with the correct count;
      tap → password sheet; correct password → import succeeds, banners disappear immediately.
- [ ] Wrong password → item stays queued, error shown, banner remains.
- [ ] Settings → "Needs password" still works exactly as before (same reused view).
- [ ] A *new* pending item during a Gmail scan fires exactly one local notification; relaunching the app
      with existing pending items fires none.
- [ ] Zero pending → no banner, no extra vertical space on Home/Accounts.
- [ ] Build green via the canonical `xcodebuild` command.
