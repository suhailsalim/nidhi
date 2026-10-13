---
name: nidhi-feature
description: End-to-end checklist for adding a user-facing feature to Nidhi — architecture slots, UI conventions, privacy constraints, and the docs/memory trail. Use when starting any new feature or screen in this repo.
---

# New-feature checklist (Nidhi)

## Before writing code

- Read `AGENTS.md` (architecture + file map) and the relevant `docs/*.md` deep-dive.
- Check `.wolf/cerebrum.md` Do-Not-Repeat and `.wolf/buglog.json` for prior art on this area.
- If a `PLAN-*.md` exists for the feature, follow it — they encode explored edge cases.

## Architecture slots (non-negotiable)

- **State & logic live on `Store`** (`Store.swift`) — views stay thin; no view-model layer, no new
  singletons for app state. Domain managers (GmailManager-style) only for external integrations.
- Persisted state → follow the `nidhi-persist` skill (tolerant decode, all four Persist touch points).
- Derived numbers are computed, never stored (balances, goal progress, spent) — hook recomputation
  into `recomputeSpent()` if your feature affects money math.
- **On-device only**: no backend, no third-party deps, no analytics. New network calls only to
  user-enabled services; anything AI-bound sends aggregates only, never raw transactions.

## UI conventions

- Reuse `Components.swift` (`LabeledField`, `LabeledAmountField`, `SectionHeader`,
  `DeleteSheetButton`, card covers) and the `Zen` palette/typography from `Theme.swift` — don't
  reinvent form rows or invent colors.
- Add/edit sheets live in `Sheets.swift`; tab screens in their `*View.swift`; INR-first formatting.
- Catalogs (`BankCatalog`, `CardCatalog`, `BrandCatalog`, `MarketCatalog`) are factual reference data —
  extend them rather than special-casing logic.
- Notifications through `Notifications.swift` helpers (permission-gated), never raw
  `UNUserNotificationCenter`.

## After the code

1. Build + launch (see `nidhi-build`); exercise the feature in the simulator, not just compilation.
2. Update the matching `docs/*.md` dev doc AND the user guide page under `docs/guide/` if user-visible.
3. OpenWolf trail: update `.wolf/anatomy.md`, append to `.wolf/memory.md`; new bugs fixed along the
   way → `.wolf/buglog.json`.
4. Never commit secrets or real statement data; screenshots only from demo-seeded simulators.
