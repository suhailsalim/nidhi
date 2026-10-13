# PLAN: Month-in-review report (shareable)

**Missing-feature rank: 8 of 10.** All the month's story exists — spend vs plan, category deltas,
top merchants, rewards earned, net-worth change, goal progress — but the user has to assemble it
mentally across five tabs. A generated month-end summary is high perceived value and pure
recombination of existing data. (Also the natural place for the opt-in AI paragraph.)

## Goal

A "Month in review" screen for any completed month: headline stats, biggest category moves vs the
3-month average, top 5 merchants, rewards + international totals, net-worth delta, budget streak —
shareable as an image (ShareLink) with **no account numbers or balances on it** (share-safe by design:
percentages and spend totals only).

## Files to touch

- **Create** `Nidhi/MonthReport.swift` — pure `struct MonthReport { static func build(month:,
  store-inputs...) -> MonthReport }` with all figures as fields; and `MonthReportView`.
- [Nidhi/UI/InsightsView.swift](Nidhi/UI/InsightsView.swift) — entry row ("June in review →"),
  month picker for past months.
- [Nidhi/UI/HomeView.swift](Nidhi/UI/HomeView.swift) — for the first 5 days of a month, a
  one-tap banner to last month's report.
- [Nidhi/AI/AIInsights.swift](Nidhi/AI/AIInsights.swift) — optional: reuse the existing
  aggregate-only summary for a closing paragraph when AI is enabled (respect the privacy rule — the
  report builder passes the same aggregates `AIInsights` already uses, nothing more).

## Implementation order

1. `MonthReport.build` (inject month + txns/categories/nwHistory/goals; no `Date()` inside): totals,
   per-category spent vs that category's 3-month trailing average (skip categories with <2 months of
   history), top merchants by spend (exclude Transfers), rewards by unit, international by currency,
   net-worth start/end from `nwHistory`, months-under-plan streak.
2. `MonthReportView`: Zen-styled scroll of cards; reuse existing chart/row components.
3. Share: render a dedicated compact `MonthReportShareView` (not the scroll view) via
   `ImageRenderer` → `ShareLink`. This view contains ONLY: month, total spent, top 3 categories with
   deltas, streak, and reward totals — no balances, no net worth, no account names. That constraint is
   the difference between a shareable and a privacy leak.
4. Entry points + month picker (only complete months selectable; current month shows "in progress"
   preview).

## Edge cases a weaker model would miss

- **Refunds**: a refunded purchase inflates "top merchants" if you sum debits only — sum net per
  merchant (debits + refund credits matched by merchant).
- **Sparse first months**: trailing averages with 0-1 months of history divide by small n — gate deltas
  on history length, show "new" badge instead.
- `nwHistory` samples daily but can have gaps (app not opened) — take nearest sample ≤ month start/end,
  not exact-date lookup.
- `ImageRenderer` needs explicit `.frame` + `scale = UIScreen.main.scale` or the share image renders
  blurry/mis-sized; render at fixed 1080-width design size.
- AI paragraph must degrade to absent (not an error card) when AI is off — the report is complete
  without it.

## Acceptance criteria

- [ ] Report figures for last month reconcile with Plan/Insights for the same month (spot-check totals
      and one category delta by hand).
- [ ] Shared image contains no account numbers, balances, or net-worth figures (visual audit).
- [ ] Month with a large refund shows sane top-merchant list.
- [ ] Works for the oldest month with data and for a month with zero txns ("quiet month" empty state).
- [ ] Build green.
