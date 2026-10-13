# PLAN: Backup rotation, integrity check, and restore preview

**Rank: 2 of 5.** All user data is ONE JSON blob in UserDefaults (`win_the_money_v1`) and the backup is
ONE file (`Nidhi-backup.json`) overwritten in place on every auto-backup
(`BackupManager.write`, [BackupManager.swift](Nidhi/State/BackupManager.swift)). Failure mode today: a
bad state (accidental "Clear all data", a bug that empties collections, a corrupted save) gets
auto-backed-up on next launch and **destroys the only backup**. For a no-backend finance app this is the
single biggest data-loss risk in the codebase.

## Goal

Rotating, timestamped backups (keep last N), a sanity check before overwriting, and a restore flow that
previews what a backup contains before applying it.

## Files to touch

- [Nidhi/State/BackupManager.swift](Nidhi/State/BackupManager.swift) — rotation, listing, integrity.
- [Nidhi/State/Store.swift](Nidhi/State/Store.swift) — `backupNow()` (~line 63), `autoBackupIfEnabled()`
  (~line 65), `restoreFromBackup` (~line 69), `exportBundle()`.
- [Nidhi/UI/Sheets.swift](Nidhi/UI/Sheets.swift) — Settings backup section (~line 1160, the
  `autoBackupEnabled` toggle area): add "Backups" list + restore preview UI.
- [Nidhi/State/Persistence.swift](Nidhi/State/Persistence.swift) — read-only reference for decoding a
  backup into `Persist` for the preview (decoding is tolerant; reuse it, don't duplicate).

## Implementation order

1. **Rotation in `BackupManager`.** Keep the stable `Nidhi-backup.json` name (latest copy —
   existing restore paths and user muscle-memory depend on it), and additionally write
   `Backups/Nidhi-backup-YYYYMMDD-HHmmss.json` in Documents (and in the iCloud container when
   available). After writing, prune to the newest 10 timestamped files per location.
2. **Sanity gate before overwrite.** In `Store.autoBackupIfEnabled()` — it already checks `hasData`;
   strengthen it: decode the *existing* latest backup's counts (txns + banks + cards + goals) and skip
   the auto-backup (keeping old backups intact) if the new export has, e.g., < 25% of the old txn count
   while the old count was > 20. Manual `backupNow()` bypasses the gate but shows the same warning text
   in the returned label. Keep the heuristic dumb and transparent — a code comment must state the rule.
3. **`BackupManager.list()`** → `[BackupInfo]{url, date, source(local/iCloud), byteSize}` sorted newest
   first, merging both locations.
4. **Preview.** `Store.previewBackup(data:) -> BackupSummary` — decode via the existing tolerant
   `Persist` decoding path used by `restoreFromBackup` (find how `apply` consumes it in Store/Persistence
   and reuse exactly that decode; do NOT write a second decoder), returning counts + date range of txns
   + last txn date. Return nil if it doesn't decode → UI shows "corrupt backup".
5. **UI in Sheets.swift Settings.** Under the existing backup row: NavigationLink "Backups" → list from
   `BackupManager.list()`; tapping a row shows the `BackupSummary` (counts vs current live counts side by
   side) with a destructive "Restore this backup" confirmation. Restore replaces current data (that's the
   existing `restoreFromBackup` semantic) — say so explicitly in the confirmation text, and auto-write a
   timestamped backup of the *current* state first, labelled `-prerestore`.
6. Build with the canonical `xcodebuild` command; run in simulator, create/restore a backup end-to-end.

## Edge cases a weaker model would miss

- **Auto-backup runs from `NidhiApp.swift:22` on launch** — that's exactly when a
  corrupted/emptied Persist would clobber the backup. The sanity gate (step 2) must run there, not only
  in Settings.
- **Secrets are intentionally excluded from backups** (OAuth tokens, AA secret, PDF passwords —
  documented in docs/persistence-and-backup.md). Don't "improve" the export by adding them.
- **iCloud may be unavailable** (free dev team, signed-out user): every iCloud path must silently no-op
  — mirror the existing `iCloudAvailable` guards. `startDownloadingUbiquitousItem` means listed iCloud
  files may exist but not be materialised; handle `Data(contentsOf:)` failure per file, not per list.
- **Restore must go through `Store.apply`/tolerant decode**, never raw-write UserDefaults — old backups
  with missing fields must load (that's the whole tolerant-Codable rule in CLAUDE.md).
- **`clearAll` (~Store.swift:1232-1259) intentionally does NOT delete backups** (comment says so).
  Rotation/pruning must also never run during `clearAll`.
- After restore, call the same recompute chain the app relies on (`recomputeSpent()` — it cascades to
  bank balances and goal progress). Check what `restoreFromBackup` already calls and keep parity.
- Prune by parsed filename timestamp, not file mtime (iCloud sync can rewrite mtimes).
- New stored properties, if any (none expected — prefer UserDefaults key for "last prerestore"), must
  follow the tolerant-decode rule.

## Acceptance criteria

- [ ] After 3 manual backups, Documents/Backups contains 3 timestamped files + the stable latest file;
      after 11, only the newest 10 timestamped remain.
- [ ] Simulate the wipe scenario: with real-ish data (import a fixture statement), toggle a temporary
      debug path or delete the UserDefaults blob so the store loads empty → relaunch → the previous
      timestamped backups still exist (auto-backup was skipped or wrote a new file without pruning the
      good ones), and restoring the newest good one brings all txns/accounts back.
- [ ] Restore preview shows txn/bank/card/goal counts and refuses (nil summary, disabled button) on a
      garbage file.
- [ ] Restoring writes a `-prerestore` backup of the pre-restore state first.
- [ ] Backup JSON contains no Keychain secrets (grep the file for `token`, `client_secret`, password
      values).
- [ ] App builds green; existing single-file backup/restore flow still works unchanged.
