# PLAN: Loans & EMI tracking (liabilities)

**Missing-feature rank: 7 of 10.** Net worth counts assets and card outstandings but has no concept of
a **loan** — home/car/personal loans, the largest liability most users have. The repo even rejects
loan-statement PDFs on import (PR #10) because there's nowhere to put them. EMI transactions are being
categorised as spending when they're substantially principal (a balance-sheet transfer).

## Goal

A `Loan` model (principal outstanding, rate, EMI, tenure, linked EMI recurring group), shown in Wealth
as negative net worth, with EMI txns auto-linked so principal reduces the loan instead of counting as
pure spend.

## Files to touch

- [Nidhi/State/Models.swift](Nidhi/State/Models.swift) — `Loan { name, lender, principal, rate, emi,
  startDate, tenureMonths, mask, counterpartyKey }` + derived `outstanding(asOf:)` via amortisation.
- [Nidhi/State/Persistence.swift](Nidhi/State/Persistence.swift) — new `Store.loans` collection into
  `Persist`/`makePersist`/`apply`/`clearAll` with tolerant decode (`default: []`).
- [Nidhi/State/Store.swift](Nidhi/State/Store.swift) — `loans` published; `liquidNetWorth` unchanged
  but add `netWorth = liquidNetWorth − Σ loans.outstanding`; classification: txns matching a loan's
  `counterpartyKey` get category "EMI & Loans" + tag "EMI" + linked loan id.
- [Nidhi/UI/WealthView.swift](Nidhi/UI/WealthView.swift) — "Loans" section (outstanding, paid %,
  months left); composition chart gains a liabilities bar.
- [Nidhi/UI/Sheets.swift](Nidhi/UI/Sheets.swift) — Add/edit loan sheet (reuse `LabeledField`/
  `LabeledAmountField`); link-to-recurring-group picker seeded from `recurringGroups`.
- [Nidhi/UI/HomeView.swift](Nidhi/UI/HomeView.swift) — net worth headline: decide (and label)
  whether Home shows liquid or net-of-loans; add a small "incl. loans" subtitle rather than silently
  changing the number users know.

## Implementation order

1. Model + amortisation math: standard reducing-balance
   `outstanding(after n payments) = P(1+i)^n − E·((1+i)^n − 1)/i`, `i = rate/1200`. Put the formula in
   a pure static with a comment; guard `i == 0`.
2. Persistence plumbing (all four Persist touch points), sheet UI, Wealth section.
3. EMI linking: user picks a recurring group (or manual counterparty); classification tags future and
   existing matching txns; loan `outstanding` uses months-elapsed amortisation, NOT txn-sum (missed
   EMI months are visible as drift — show both "scheduled outstanding" and "based on N EMIs seen").
4. Wealth/Home display; milestone ladder stays on **liquid** net worth (its semantics predate loans —
   changing it silently would move users' milestones; leave and document).

## Edge cases a weaker model would miss

- **Do not double-subtract**: EMI txns already reduce bank balances (real cash out). The loan's
  `outstanding` is computed from amortisation, not from txns — so net worth = (banks already net of
  EMIs paid) − (amortised outstanding). Summing EMI txns into the loan as well would double-count.
- **Prepayments** break pure amortisation — add an optional `principalAdjustments: [(Date, Double)]`
  list (manual entry) applied to the schedule; PR #10's rejected foreclosure statements are exactly
  this case, so leave a hook, not a parser.
- Rate changes (floating loans): out of scope; a manual "recalibrate outstanding" field (sets a new
  anchor principal + date — mirroring the bank balance-anchor pattern) covers it cheaply and matches
  an established repo idiom.
- The "EMI & Loans" category already exists in classification (bug-042 context) — link to it, don't
  create a duplicate.
- Widgets/snapshot read net-worth figures — check `NidhiShared` snapshot fields before renaming anything.

## Acceptance criteria

- [ ] A ₹30L/8.5%/240-month loan shows the textbook outstanding after 12 EMIs (verify against any
      online amortisation calculator, ±₹1).
- [ ] Linking a recurring EMI group tags its txns and shows "N EMIs seen" matching reality.
- [ ] Wealth shows loans as negative; Home headline unchanged in meaning (labelled).
- [ ] Old backups restore; deleting a loan un-links txns but keeps them; build green.
