# Persistence & backup

## Storage

All app data is a single JSON `Persist` blob in `UserDefaults` (key `win_the_money_v1`), written by
`Store.save()` and read by `Store.load()`. Secrets are **not** here — they live in the Keychain
(`Keychain.swift`, `StatementVault.swift`). Some flags use their own `UserDefaults` keys
(`gmail_done_stmts`, `nidhi_cat_lib_v`, `nidhi_nw_day`, Gmail/AA settings).

## The tolerant-decoding rule (do not break)

`Persistence.swift` gives every persisted model a custom `init(from:)` that decodes each field with a
**default fallback** via `KeyedDecodingContainer.decode(_:default:)`. This means saved JSON from older
versions still loads after you add fields — the new field just gets its default. Decoding must **never**
throw on a missing/null/mismatched key.

### When adding a stored property to a persisted struct

1. Add the property (with a sensible default where used/seeded).
2. Add a `case` to that struct's `CodingKeys`.
3. Add one line to its `init(from:)`: `x = c.decode(.x, default: <default>)`.

### When adding a whole new collection to `Store`

Add it to `Persist` and decode it the same way (`decode(.x, default: [])`).

Enums that may gain/lose cases decode via `rawValue` with a fallback (e.g. `InvestmentKind → .stock`,
`GoalStatus → .onTrack`, `TxnSource → .unknown`).

## Backup / export-import

`BackupManager.swift` exports the full dataset to a user-chosen file (e.g. iCloud Drive) and re-imports it
on another device. **Secrets (OAuth tokens, AA client secret, PDF passwords) are intentionally excluded.**
`autoBackupEnabled` drives periodic backups. "Clear all data" wipes the `Persist` blob and resets
integration state (including the Gmail processed-statement ledger).
