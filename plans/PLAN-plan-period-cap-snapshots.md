# PLAN: Historical budget-cap snapshots for Plan period navigation

**Rank: 4 of 5.** Known limitation recorded when Plan periods shipped (PR #11): budget caps are global —
navigating to a past month in PlanView shows that month's *actual* spend against the *current* cap. If
the user raises Groceries from ₹8k to ₹12k in July, June retroactively looks under-budget and the
over/under history (`Store.planMonths`, home trend, insights) lies. Fix: snapshot each category's
monthly plan per month, so past periods compare against the cap that was in force then.

## Goal

A persisted `capHistory: [String: Double]` per category keyed by month (`"YYYY-MM"` → monthlyPlan at that
time). Past-period reads use the snapshot; the current period keeps using the live cap. Editing a cap
never rewrites history.

## Files to touch

- [Nidhi/State/Models.swift](Nidhi/State/Models.swift) — `BudgetCategory` (fields around line 46:
  `periodMonths`, `monthlyPlan`): add `capHistory: [String: Double] = [:]` and a helper
  `plan(forMonth:)`.
- [Nidhi/State/Persistence.swift](Nidhi/State/Persistence.swift) — tolerant decode line:
  `capHistory = c.decode(.capHistory, default: [:])` (**mandatory** — see CLAUDE.md rule).
- [Nidhi/State/Store.swift](Nidhi/State/Store.swift) — snapshot writer; `recomputeSpent()` (~278) is the
  natural hook since it already runs on every mutation path. `planMonths` (~320) switches to snapshots.
- [Nidhi/UI/PlanView.swift](Nidhi/UI/PlanView.swift) — `plan(c)` override for non-current windows
  (~line 170 `CategoryRow(... planOverride: plan(c) ...)` and `window(mode:offset:)` at ~193).

## Implementation order

1. Model: add `capHistory` to `BudgetCategory` + CodingKeys case + tolerant decode line in
   Persistence.swift. Helper: `func plan(forMonth key: String) -> Double` returning
   `capHistory[key] ?? monthlyPlan` (fallback = current cap, so pre-feature history behaves exactly as
   today — no migration needed).
2. Snapshot writer in Store: `func snapshotCaps()` — for the *current* calendar month key, write
   `capHistory[key] = monthlyPlan` for every category, and prune keys older than ~36 months. Call it
   from `recomputeSpent()` (cheap: dictionary writes) so it stays current as caps are edited during the
   month. The month's final snapshot is therefore "the cap at the last moment of that month" — the
   correct semantic. Add a one-line comment stating this.
3. Past-period reads:
   - `Store.planMonths` (~320): for each past month `i`, use `c.plan(forMonth: key)` instead of
     `monthlyPlan` when computing pct.
   - PlanView `plan(c)`: for monthly mode with `offset != 0`, use the snapshot for that month; for
     multi-month windows (YTD/FYTD/year), sum the per-month snapshots across the window's months.
     Current month always uses live `monthlyPlan` (so an in-month cap edit reflects immediately).
4. Build, then verify in simulator: set a cap, note a past month's bar, change the cap, confirm the past
   month's bar/percentage does NOT move but the current month's does.

## Edge cases a weaker model would miss

- **Non-monthly periods** (quarterly/annual/custom — `BudgetCategory.period` + `cycleWindow` at
  Store.swift:300): `monthlyPlan` is already cap ÷ periodMonths, so snapshotting `monthlyPlan` per month
  is correct and uniform. Do NOT snapshot the raw `plan`.
- **Current month must stay live.** If step 3 snapshots-then-reads for offset 0, an in-month edit works
  only because the snapshot is rewritten in `recomputeSpent` — but a cap edit that doesn't trigger
  recompute would show stale. Safer: current month reads live `monthlyPlan` unconditionally.
- **Category renames**: check how categories are keyed elsewhere (`spend(inCategory: name ...)`
  Store.swift:330 uses the *name*). `capHistory` lives inside the `BudgetCategory` struct so it survives
  renames — good; don't move it to a name-keyed dictionary on Store.
- **Deleted categories** lose their history — acceptable and consistent with existing behaviour
  (spend attribution also degrades); note it in the code comment, don't build tombstones.
- **`monthKey` must be locale/timezone-stable**: build it with `Calendar.current` year/month ints
  (`String(format: "%04d-%02d", y, m)`), not `DateFormatter` with default locale.
- **Widgets/snapshot**: `planMonths` feeds the home trend; after changing it, confirm the widget
  snapshot path (`NidhiShared.snapshotURL`, Store.swift:~1259 region) still compiles/renders.
- Persistence: forgetting the tolerant-decode default will make ALL existing user data fail to load —
  this is the #1 repo rule. Double-check the decode line exists before building.

## Acceptance criteria

- [ ] Editing a cap changes the current month's Plan figures but leaves all past months' pct/over-flags
      unchanged (verify via `planMonths` and PlanView ‹ navigation).
- [ ] A fresh install / pre-feature backup restores cleanly (no decode failure; past months fall back to
      current cap exactly as today).
- [ ] YTD/FYTD/year windows show plan = Σ per-month snapshots (spot-check one category by hand).
- [ ] Month rollover: simulate by writing a snapshot for last month, editing the cap, confirming last
      month keeps the old value.
- [ ] `capHistory` is pruned (no unbounded growth) — inspect the Persist blob after multiple snapshots.
- [ ] Build green; app launches; no persistence errors in console.
