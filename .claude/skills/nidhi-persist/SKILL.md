---
name: nidhi-persist
description: Add or change persisted data in Nidhi (stored properties, new Store collections, settings keys) without breaking existing user data. Use whenever touching Models.swift, Persistence.swift, or adding @Published state that must survive relaunch.
---

# Persistence checklist (Nidhi)

All data is one JSON `Persist` blob in UserDefaults (`win_the_money_v1`). Decoding must **NEVER
throw** — old blobs must load after any change. This is the repo's #1 rule; breaking it bricks the
user's data.

## Adding a stored property to a persisted struct

1. Add the property in `Models.swift` with a sensible default.
2. Add its `case` to that struct's `CodingKeys` in `Persistence.swift`.
3. Add the tolerant decode line in that struct's `init(from:)`:
   `x = c.decode(.x, default: <default>)`  ← forgetting this line is the classic failure.

## Adding a whole new collection to Store

Wire ALL FOUR places or data silently drops: `Persist` (field + decode `default: []`),
`Store.makePersist`, `Store.apply`, `Store.clearAll`.

## Rules & idioms

- Enums that may gain/lose cases decode via rawValue with a fallback (`InvestmentKind → .stock`,
  `TxnSource → .unknown`) — never raw `decode(Enum.self)`.
- Secrets (tokens, passwords, API keys) go in the **Keychain** (`Keychain.swift`,
  `StatementVault.swift`), never in Persist and never in backups.
- Device-local flags (lock settings, ledgers like `gmail_done_stmts`) use their own UserDefaults keys,
  not Persist — they must not travel in backups/restores.
- After mutating data-affecting state, the recompute chain is `recomputeSpent()` — it cascades to bank
  balances (`recomputeBankBalances`) and goal progress (`recomputeGoalProgress`). Balances are always
  **derived** (anchor + later txns); never write `balance` directly — set an anchor via
  `setBalanceAnchor` (forward-in-time only).

## Verify

Build (see `nidhi-build`), launch, confirm no decode reset (existing data still visible), and ideally
restore an old backup JSON through Settings to prove tolerance. Update
`docs/persistence-and-backup.md` if you added a collection.
