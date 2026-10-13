# PLAN: Credit-card bill due dates & payment reminders

**Missing-feature rank: 2 of 10.** Card statements are already parsed — but the **payment due date,
total due, and minimum due** printed on every statement are discarded. Missing a card payment is the
single most expensive mistake this app could prevent. High value, and the parsing infrastructure
already exists.

## Goal

Each `CreditCard` knows its current statement's `totalDue`, `minDue`, `dueDate`; the card cover and
Home show "due in N days"; local notifications fire before the due date; detecting the bill-payment
transaction clears the reminder.

## Files to touch

- [Nidhi/State/Models.swift](Nidhi/State/Models.swift) — `CreditCard`: add `totalDue`, `minDue`,
  `dueDate`, `dueClearedAt` (all optional).
- [Nidhi/State/Persistence.swift](Nidhi/State/Persistence.swift) — tolerant decode lines (defaults nil)
  — **mandatory**, see the rule in docs/persistence-and-backup.md.
- [Nidhi/AccountAggregator/BankSync.swift](Nidhi/AccountAggregator/BankSync.swift) — `SyncedAccount`: carry the three fields.
- [Nidhi/Statements/CardStatementParser.swift](Nidhi/Statements/CardStatementParser.swift) — extract per issuer
  in each parser + thread through `cardAccount(...)` (~line 284).
- [Nidhi/State/Store.swift](Nidhi/State/Store.swift) — `upsertAccount`: write to the card (only when
  the statement is *newer* than the current `dueDate`); clear when a Transfer-classified payment ≥
  `minDue` to that card lands after the statement date.
- [Nidhi/Platform/Notifications.swift](Nidhi/Platform/Notifications.swift) — schedule/cancel
  `UNCalendarNotificationTrigger`s (T-3 days and due-day morning), id `carddue-<mask>`.
- [Nidhi/UI/AccountsView.swift](Nidhi/UI/AccountsView.swift) + Home — due chip on card cover;
  Home banner when any card is due within 5 days and uncleared.

## Implementation order

1. Dump the label text around due dates from the real card PDFs (use the parser harness `--dump` from
   PLAN-parser-regression-harness): HDFC prints "Payment Due Date", Axis "Payment Due Date", ICICI and
   Scapia have equivalents. Write per-issuer regexes next to each parser's existing summary extraction.
2. Model + persistence + DTO plumbing; then `upsertAccount` write + the clearing rule.
3. Notifications: reschedule on every statement import and on clearing (cancel by id). Never schedule
   for past dates.
4. UI chips/banner (reuse `Components.swift` patterns), then verify via the harness (new expectation
   fields: `dueDate`, `totalDue` presence per card fixture) and in-app.

## Edge cases a weaker model would miss

- **Statement date ordering**: an old statement re-imported must not resurrect a stale due date —
  compare against `SyncedAccount.asOf`, mirroring the balance-anchor forward-only rule.
- **Payment detection** must reuse the existing Transfer classification (`Store.classify` step 1 —
  card-bill payments are already recognised); don't write a second matcher. Partial payments (≥ minDue
  but < totalDue) clear the *notification*, but the UI should still show remaining due.
- Due dates in card PDFs are DD/MM/YYYY — parse with an explicit `en_IN`-safe formatter, never
  `DateFormatter` defaults; a US-locale parse silently swaps day/month.
- Notification permission may be denied — the chip/banner must work regardless.
- `dueClearedAt` exists so a payment made *before* you re-import the next statement doesn't re-alert.

## Acceptance criteria

- [ ] Harness: each card fixture reports the printed due date/total due/min due exactly (hand-check
      against the PDFs once; record in expectations).
- [ ] Importing a card statement schedules 2 notifications; paying the bill (import/log a Transfer to
      that card ≥ minDue) cancels them and flips the chip to "Paid".
- [ ] Re-importing an older statement changes nothing.
- [ ] Pre-feature backups restore cleanly (tolerant decode verified by restoring an old backup).
- [ ] Build green.
