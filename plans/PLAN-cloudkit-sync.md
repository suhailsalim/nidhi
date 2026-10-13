# PLAN: Multi-device sync via CloudKit (iPhone ↔ iPad)

**Missing-feature rank: 10 of 10 — largest scope, do last.** Today the dataset lives on one device;
the iCloud backup file gives migration, not sync. CloudKit (private database) is the only sync option
compatible with the app's identity: end-to-end within the user's own iCloud, no third-party server,
no new accounts. Ranked last because it touches persistence architecture and needs a paid-team
entitlement decision.

## Goal

Opt-in sync of the `Persist` blob across the user's devices via CloudKit private DB — last-writer-wins
at the *collection-merge* level (not blob level), with the existing dedup/anchor machinery doing the
heavy lifting.

## Pre-requisite decision (surface to the user before starting)

- CloudKit needs the iCloud entitlement — **not available on the free personal team** (BackupManager
  already degrades for this reason). Confirm a paid Apple Developer membership is available; if not,
  stop at step 1 (design doc) and keep this plan parked.

## Files to touch

- **Create** `Nidhi/CloudSync.swift` — CKContainer private DB; one record type `NidhiChangeSet`
  (device id, timestamp, zlib-compressed JSON payload) in a custom zone with `CKSyncEngine` (iOS 17+)
  handling push/fetch scheduling.
- [Nidhi/State/Store.swift](Nidhi/State/Store.swift) — `mergeRemote(_ persist: Persist)`: a
  collection-aware merge (see below); a `dirty` flag piggybacking on `save()`.
- [Nidhi/State/Persistence.swift](Nidhi/State/Persistence.swift) — reuse `Persist` encoding for the
  payload; add per-record `updatedAt` ONLY where merge needs it (txns already have dates + externalIds;
  accounts have anchors with asOf — most merge keys already exist).
- [Nidhi/UI/Sheets.swift](Nidhi/UI/Sheets.swift) — Settings "Sync across devices" toggle +
  status row; entitlements for both configurations.

## Implementation order

1. Write `docs/dev-sync-design.md` first: the merge rules per collection (this is the real work — the
   networking is boilerplate). Rules that fall out of existing invariants:
   - **Txns**: union by `id`/`externalId` → the existing dedup path (`mergeSynced`-style keys) removes
     cross-device duplicates; conflicts on the same id → newer edit wins (needs `Txn.updatedAt`).
   - **Accounts/cards**: upsert by mask; balance anchors already resolve by `asOf` forward-only — the
     iron-clad rule is literally a CRDT; keep it.
   - **Categories/goals/settings**: last-writer-wins per item by `updatedAt`.
   - **Deletes**: need tombstones (`deletedIds: [UUID: Date]`, pruned after 90 days) — without them,
     sync resurrects everything deleted on one device. This is the classic miss.
2. `updatedAt` fields + tombstone set with tolerant decode defaults (the persistence rule).
3. `CloudSync` with `CKSyncEngine`; payload = full compressed `Persist` initially (simple, correct);
   merge applies remote through `mergeRemote`, then `recomputeSpent()` (rederives balances/goals —
   the derived-everything architecture makes sync far safer than it'd be elsewhere).
4. Settings toggle; initial-sync flow (existing data on both devices → merge, prove no duplicates).
5. Extensive two-simulator testing (two booted simulators, same iCloud account, or device+simulator).

## Edge cases a weaker model would miss

- **Secrets never sync** — Keychain items (passwords, tokens) stay per-device by design; after first
  sync the second device must show the "reconnect Gmail / re-enter passwords" affordances, not crash
  into empty-token paths.
- The Gmail processed-statement ledger (`gmail_done_stmts`) is per-device UserDefaults — if both
  devices scan the same mailbox, the txn-level dedup (externalIds) is the real guard; verify a
  double-scan converges to one txn set.
- `recomputeSpent` after merge is what keeps balances right — a merge that writes `balance` directly
  would fight the anchor system; only anchors + txns sync, balances stay derived.
- CK record size limit ~1MB — compress, and if the blob outgrows it, split payload per collection
  (design the record schema for that now: one record per collection, not one total).
- Offline edits on both devices: LWW per item means a category edited on both keeps the newer — state
  this loss model plainly in Settings copy ("rare simultaneous edits: newest wins").

## Acceptance criteria

- [ ] Two devices, disjoint data → after sync both show the union, zero duplicate txns/accounts.
- [ ] Delete a txn on A → gone on B (tombstone), and re-sync doesn't resurrect it.
- [ ] Edit the same goal on both while offline → newer edit wins everywhere, no crash.
- [ ] Balances identical on both (derived, not copied).
- [ ] Airplane-mode edits queue and sync later; toggle off stops all CK traffic.
- [ ] Old single-device backups still restore; build green on both targets.
