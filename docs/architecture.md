# Architecture

## Data flow

```
Views (SwiftUI)  ⇄  Store (ObservableObject)  ⇄  Persistence (UserDefaults JSON)
                         │
                         ├─ Importers/Providers write into Store collections
                         └─ derived totals computed on Store (net worth, spent, P&L…)
```

`Store` (`Nidhi/State/Store.swift`) is the **single source of truth**. It owns every `@Published`
collection, all mutations (add/update/remove/merge), and all derived values. Views are thin: they read
published state and call `Store` methods. There is no separate view-model layer.

## Store: key published state

`tab, categories, txns, banks, cards, deposits, goals, milestones, badges, investments,`
`incomeStreams, deductions, taxTotal, advanceTaxPaidStages, merchantRules, fxRates, nwHistory`,
plus profile/settings (`userName, netWorthTarget, preferStatementImport, accountAggregatorEnabled,`
`notificationsEnabled, autoBackupEnabled`).

## Store: representative responsibilities

- **Derived totals**: `liquidNetWorth`, investments total, per-category `spent`, card outstanding,
  live bank balance (`recomputeBankBalances`: anchor + transactions after `balanceAsOf`), etc.
- **Transactions**: `add`, `classify(merchant:counterparty:narration:income:)`, `recategorizeAll()`,
  `mergeImport(_:)`, `mergeSynced(accounts:txns:)`, `mergeStatement(account:txns:)`, `applyBalances(_:)`.
- **Accounts**: `upsertAccount`, `mergeDeposits(_:)` (upsert by identifier), `dedupeAccountNames`.
- **Categories**: `baseCategories` (locked set), `ensureBaseCategories`, `symbolFor`, `migrateRentBills`.
- **Merchant learning**: `merchantRules` (manual overrides), `learnMerchant`.
- **Gamification**: XP/level, `milestones`, `badges`, `refreshMilestones`.
- **Net worth history**: `nwHistory` sampled per day (`nidhi_nw_day`).

## Models (`Models.swift`)

Plain `Codable` structs/enums: `BudgetCategory, Txn, TxnSource(.bank/.card/.unknown), BankAccount,`
`CreditCard, Deposit, InvestmentKind(.stock/.etf/.mutualFund), Investment, Goal, GoalStatus, Milestone,`
`Badge, IncomeStream, PlanMonth, Segment, Tab, Currencies`. Custom decoders live in `Persistence.swift`.

## UI

- `RootView` — 6-tab `TabView`: **Home, Plan, Insights, Goals, Wealth, Income**.
- `AccountsView` — manage banks & cards (+ statement import entry points).
- `Sheets.swift` — add/edit sheets (transaction, account, card, deposit, investment, goal, income),
  Settings, Gmail/AA settings, merchants & rules, pending statements.
- `Components.swift` / `Theme.swift` — the `Zen` design system (reusable rows, cards, colours).

## Background & platform

`NidhiApp` injects `Store` and schedules `BGTask`s (`…gmailrefresh`, `…stmtrefresh`). See
[integrations.md](integrations.md) for Gmail/AA/notifications/widgets.
