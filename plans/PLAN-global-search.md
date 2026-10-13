# PLAN: Global transaction search & filters

**Missing-feature rank: 4 of 10.** With statements + Gmail feeding thousands of transactions, there is
no way to answer "when did I last pay the dentist?" — lists are only pre-filtered by account/category/
tag (`TransactionsSheet(account:category:tag:)`). Search is table-stakes once data volume grows.

## Goal

A search field on the transactions list (`.searchable`) matching merchant, counterparty, narration/raw
context, amount, and tags — plus composable filter chips (account, category, tag, date range, amount
range, international-only, needs-review).

## Files to touch

- [Nidhi/State/Store.swift](Nidhi/State/Store.swift) — `func searchTxns(_ query: String, filter:
  TxnFilter) -> [Txn]` + a `TxnFilter` struct (all fields optional). Pure, no state.
- [Nidhi/UI/Sheets.swift](Nidhi/UI/Sheets.swift) — `TransactionsSheet`: add `.searchable`,
  filter chip bar, and migrate its existing account/category/tag presets to be initial `TxnFilter`
  values (the preset init from PR #11 must keep working unchanged for existing call sites).
- [Nidhi/UI/HomeView.swift](Nidhi/UI/HomeView.swift) — a search icon opening the full list.

## Implementation order

1. `TxnFilter` + `searchTxns`: normalise both query and fields (casefold, strip diacritics). Amount
   query: if the query parses as a number, match `abs(amount)` within ±0.5 as well as text. Multi-word
   queries AND across words (each word can hit a different field).
2. Wire into `TransactionsSheet` — filtering applies to the *already preset-filtered* base list, so the
   drill-in flows compose with search instead of being replaced.
3. Chip bar: category and account chips populated from live Store collections; date range via two quick
   presets (This month / FY) + custom pickers. Chips reflect and edit the same `TxnFilter`.
4. Entry point from Home; verify performance with the full dataset.

## Edge cases a weaker model would miss

- **Search must cover `counterparty` and the merchant text**, not just the display name — UPI payees
  live in `counterparty` (Models.swift:70) and often differ from the cleaned merchant.
- `Txn.rawContext`-style narration exists only as transient import data — do NOT try to search it from
  `Txn` unless it's actually persisted (check `Txn` in Models.swift; if absent, search what exists and
  don't add heavy stored text for this).
- Amount sign: users type "649", the txn stores −649 — always match on `abs`.
- Performance: thousands of txns × per-keystroke filtering — debounce via `.searchable`'s natural
  behaviour and precompute a lowercase search blob per txn (computed once per txns change, cached),
  not per keystroke.
- Keep `isSystem` behaviours (Transfers) visible in search results even if hidden from spend lists —
  finding a bill payment is a legit search.

## Acceptance criteria

- [ ] Query by merchant fragment, UPI payee, tag, and bare amount each find the expected rows.
- [ ] Drill-in from a Plan category, then typing a query, narrows within that category.
- [ ] Filters combine (category + date range + international) and clear individually via chips.
- [ ] No visible lag typing with a full dataset (thousands of rows) on device/simulator.
- [ ] Existing `TransactionsSheet` call sites compile unchanged; build green.
