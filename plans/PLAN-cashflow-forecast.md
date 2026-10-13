# PLAN: Cash-flow forecast & safe-to-spend

**Missing-feature rank: 6 of 10.** The app knows income streams (amount + credit day), predicted
recurring charges (after PLAN-subscription-reminders), card dues (after PLAN-card-due-reminders),
budget caps, and live balances — everything needed to answer the question users actually have:
**"how much can I safely spend before month-end?"** Nothing computes it.

**Dependency:** best after PLAN-subscription-reminders and PLAN-card-due-reminders (their predictions
are inputs). Can ship degraded without them (income − budget-remaining only).

## Goal

A Home headline card: **Safe to spend today: ₹X** with a tappable breakdown, and a 30-day projected
balance sparkline (bank balances + known inflows − known outflows).

## Files to touch

- **Create** `Nidhi/Forecast.swift` — pure `struct CashflowForecast { static func compute(...) }`
  taking (banks, incomeStreams, upcomingCharges, cardDues, categories, txns, today) → daily projected
  balance array + safeToSpend. Pure and injectable-date so the parser-harness pattern can test it.
- [Nidhi/State/Store.swift](Nidhi/State/Store.swift) — thin computed `var forecast` assembling inputs.
- [Nidhi/UI/HomeView.swift](Nidhi/UI/HomeView.swift) — the card + breakdown sheet.

## Implementation order

1. `Forecast.compute` over the next 30 days: start = Σ bank balances (NOT deposits/investments —
   liquid only); each day add income streams crediting that day (`creditDay`), subtract predicted
   recurring charges, card `totalDue` on its due date, and remaining *discretionary* budget spread
   evenly over remaining days (`Σ max(0, monthlyPlan − spent)` ÷ days left).
2. `safeToSpend` = max(0, min over the horizon of projected balance) minus a buffer — but expressed
   per-day: `(projected month-end surplus) / days remaining`. Keep BOTH figures; show "₹X/day" small
   and the month-end surplus big. Document the formula in a code comment — it must be explainable in
   the breakdown sheet line by line.
3. Breakdown sheet: starting balances, + expected income (per stream), − upcoming bills (list), −
   remaining budgets, = surplus. Every line tappable to its source screen where one exists.
4. Home card with the sparkline (reuse the existing trend-chart component from Home/Wealth — check
   `Components.swift`/HomeView for the chart used by `nwHistory` and reuse it).

## Edge cases a weaker model would miss

- **Card dues double-count with budgets**: the spend that built the card bill was already counted in
  category budgets when it happened. The card due is a *cash* outflow but not new *spend* — in the
  projection it reduces bank balance (correct) but must NOT also appear as budget outflow. Keep the
  two ledgers (cash vs spend) separate in the breakdown copy.
- **Transfers/SIPs**: a recurring SIP is a cash outflow (reduces safe-to-spend) even though it's not
  "spending" — include Transfer-classified recurring groups in cash outflows, excluded from budgets.
  This is exactly the split PLAN-subscription-reminders establishes.
- **Salary already received this month** must not be re-added — a stream whose `creditDay` has passed
  AND whose matching Income txn exists this month contributes zero going forward; if the income txn is
  missing (salary late), still project it on `creditDay`+grace, flagged "expected".
- Negative safe-to-spend is meaningful — show it honestly in warning tone ("₹−4,200 short of plan"),
  never clamp to 0 in the UI (clamp only the per-day figure).
- No `Date()` inside `compute` — inject today (repo rule from the statement-date bug).

## Acceptance criteria

- [ ] Breakdown lines sum exactly to the headline figure (assert in code, not just UI).
- [ ] Receiving salary (import/log the income txn) doesn't double it; deleting it re-projects.
- [ ] A card due within the horizon visibly dips the sparkline on its due date.
- [ ] Hand-check one full scenario: 2 banks + 1 income stream + 2 subscriptions + 1 card due — verify
      the month-end number by hand against the formula comment.
- [ ] Build green.
