# Execution plans

Self-contained implementation plans, written so a less capable model can execute them without
questions. Each has: goal, exact files, step order, edge cases found during exploration, and
verifiable acceptance criteria.

**This file is the index of record.** Status below was re-verified against the code on 2026-07-15.
Don't trust a plan's own `Rank: X of Y` header — those still carry the original pre-#14 numbering and
no longer match this list.

## Core improvements (ranked — do in order)

1. [PLAN-parser-regression-harness.md](PLAN-parser-regression-harness.md) — checked-in one-command
   parser test harness. **Prerequisite for parser work.** Scope has shrunk: the HDFC EMI-marker fix it
   was written to land already shipped in #14, so step 1 is done — this is now the harness + assertions
   only. Note the four fixture PDFs are gitignored, so they exist only in the main working copy, not in
   worktrees.
2. [PLAN-axis-scapia-per-txn-rewards.md](PLAN-axis-scapia-per-txn-rewards.md) — EDGE Miles per-txn
   parsing (needs #1). Still open despite #11/#12: `parseHDFC` and `parseICICI` emit per-row rewards,
   but `parseAxis`/`parseScapia` capture only the *account-level* balance via `cardAccount(reward:)`.
   #12 did Axis MCC + forex, not rewards.

## Missing features (ranked)

1. [PLAN-cloudkit-sync.md](PLAN-cloudkit-sync.md) — multi-device sync (needs paid dev team; do last)

## Web

- [PLAN-website.md](PLAN-website.md) — landing page + `.github/workflows/site.yml` are committed,
  but **not published**: Pages must be switched to "Source: GitHub Actions" in repo Settings by hand,
  and the workflow only runs on `main`. Screenshots are placeholders, not real captures.

## Shipped

- [PLAN-loans-emi-tracking.md](PLAN-loans-emi-tracking.md) — `Loan`/`LoanAdjustment` models, pure
  `LoanMath` amortisation (injected dates), EMI→loan txn linking, net-worth-net-of-loans, Wealth
  section. Persistence independently round-trip verified. **EMI auto-linking is unexercised at runtime.**

- [PLAN-app-intents-quick-log.md](PLAN-app-intents-quick-log.md) — Siri/Shortcuts quick logging +
  interactive widget. Reading figures aloud is off by default (`nidhi_siri_read_figures`). Intent
  drain/dedup was driven on the simulator; **Siri voice and the widget itself are unexercised**.
- [PLAN-monthly-report.md](PLAN-monthly-report.md) — pure `MonthReport` builder (injected date) +
  share card carrying figures only, no accounts or balances. **The rendered image is unreviewed.**

- [PLAN-cashflow-forecast.md](PLAN-cashflow-forecast.md) — pure `CashflowForecast` (injected date),
  safe-to-spend headline, 30-day sparkline, reconciling breakdown sheet.
- [PLAN-subscription-reminders.md](PLAN-subscription-reminders.md) — cadence inference, next-charge
  prediction, fixed-vs-variable burn split, muting, T-1 reminders.

- [PLAN-global-search.md](PLAN-global-search.md) — `.searchable` transaction search over merchant,
  UPI payee, category, account, tags and bare amounts, composing with drill-in presets.

- [PLAN-txn-export.md](PLAN-txn-export.md) — `TxnExporter` CSV (14 cols, RFC-4180, UTF-8 BOM) + JSON
  DTO; exports the filtered list from the transactions toolbar and everything from Settings.

- [PLAN-plan-period-cap-snapshots.md](PLAN-plan-period-cap-snapshots.md) — per-month `capHistory`
  snapshots so past periods are judged against the cap in force then; current month stays live.
- [PLAN-backup-rotation-and-safety.md](PLAN-backup-rotation-and-safety.md) — rotating timestamped
  backups (newest 10 per location), auto-backup shrink gate, restore preview + per-backup restore.
  Rotation/pruning verified by a sandboxed swiftc harness, not just a compile.
- [PLAN-app-lock.md](PLAN-app-lock.md) — Face ID lock + app-switcher privacy cover (#16).
- [PLAN-card-due-reminders.md](PLAN-card-due-reminders.md) — card due dates + T-3/due-day reminders (#17).
- [PLAN-pending-statement-surfacing.md](PLAN-pending-statement-surfacing.md) — Home + Accounts banners
  reusing `StatementsEmailView`, plus the local notification (#18). Fully shipped: the notification
  fires from the scan loop ([GmailManager.swift:123](../Nidhi/Gmail/GmailManager.swift)) when the
  pending count grows, so it's one per scan and never fires on launch rehydration.
</content>
</invoke>
