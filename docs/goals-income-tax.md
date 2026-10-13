# Goals, income, tax & net worth

## Net worth

`Store.liquidNetWorth = banks + deposits + investments` (cards/outstanding reduce it as applicable).
`nwHistory` samples net worth once per day (`nidhi_nw_day`) to drive the Wealth/Home trend charts.
`netWorthTarget` and `milestones` track progress (see [gamification.md](gamification.md)).

## Goals (`Goal` / `GoalStatus`)

`{ title, symbol, saved, target, monthly, deadline, status(.onTrack/...) }`. `GoalsView.swift` shows
progress, required monthly contribution, and on-track status. Pure local state on `Store.goals`.

## Income (`IncomeStream`) — `IncomeView.swift`

`{ name, symbol, annual, currency, monthly, accountId, creditDay }`. Income streams feed expected monthly
inflow and can be linked to an account + a credit day. Non-INR streams convert via `FXProvider`.

## Tax (`TaxEngine.swift`, `TaxProfile`, `Payslip`)

A real slab-based India income-tax estimate (FY 2025-26 / AY 2026-27). `Store.taxProfile` holds the
inputs; `Store.tax` (`TaxEngine.compute`) returns a `TaxComputation` with **both regimes**, the
recommended (cheaper) one, a slab-wise breakdown, 87A rebate (incl. the new-regime ₹12L cliff + marginal
relief), surcharge and 4% cess. `Store.taxTotal` is now *computed* from this (the old manual
`taxTotal`/`deductions` were removed — migrated via tolerant decode).

- **Tracks** (`IncomeTrack`): salaried, self-employed (44ADA, 50% presumptive), business (44AD, 6%/8%),
  mixed — decide how taxable income is built.
- **Payslips** (`PayslipParser.swift`): import a salary-slip PDF → basic/HRA/PF/TDS/net; `Store.payslips`
  feeds YTD TDS, salary components and a projected annual salary (`applyPayslipsToProfile`).
- **Planning**: `IncomeView` shows the regime comparison, slab breakdown, planning tips (80C/80CCD(1B)/80D
  headroom, rebate-cliff nudge, advance-tax warning) and the advance-tax instalment schedule.
- **Indicative only — not tax advice.** Slabs live as data in `TaxEngine` for easy yearly updates.
