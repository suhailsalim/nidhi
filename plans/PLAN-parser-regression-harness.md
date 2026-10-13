# PLAN: Checked-in parser regression harness (+ land the pending EMI fix)

**Rank: 1 of 5 — do this first.** The repo has **no test target**; every parser change is verified by
hand-rebuilding a throwaway `swiftc` harness. The buglog (`.wolf/buglog.json`, 42 entries) is dominated
by parser and balance regressions. A permanent, one-command harness protects all future work, including
the other four plans. It also lands the currently-uncommitted, already-verified fix in
`Nidhi/Statements/CardStatementParser.swift` (HDFC "EMI " eligibility-prefix strip, bug-042).

## Goal

`tools/parser-harness/run.sh` compiles the real parser sources with `swiftc`, runs them against local
(gitignored) statement PDFs, and asserts expectations from a checked-in **redacted** expectations file.
Exit 0 = all pass. Never commits real PDFs or real amounts.

## Files to touch

- **Create** `tools/parser-harness/run.sh` — the runner.
- **Create** `tools/parser-harness/Stubs.swift` — stub DTOs (see below).
- **Create** `tools/parser-harness/main.swift` — loads PDFs, runs parsers, checks expectations.
- **Create** `tools/parser-harness/expectations.json` — checked in, redacted (hashes/counts, no amounts).
- **Create** `tools/parser-harness/fixtures/` + add `tools/parser-harness/fixtures/` to `.gitignore`
  (also gitignore `tools/parser-harness/a.out` and `*.o`).
- **Commit** the pending diff in `Nidhi/Statements/CardStatementParser.swift` (already in working tree — do
  NOT rewrite it; it is verified).
- **Edit** `AGENTS.md` and `docs/statements-and-import.md` — replace the "rebuild a harness by hand"
  instructions with `tools/parser-harness/run.sh`.

## Implementation order

1. Commit the working-tree diff first on a branch (e.g. `parser-harness`), message:
   `HDFC: strip "EMI " eligibility marker from merchant names (bug-042)`.
2. Build `Stubs.swift`. The real parser files reference app types; the harness compiles the parser files
   **unmodified** alongside stubs. Determine the exact set needed by attempting compilation and reading
   errors — expected set based on `BankSync.swift`: `SyncedAccount`, `SyncedTxn`, `ImportResult`,
   `Deposit`, `BalanceUpdate`, plus anything `StatementParsers.swift` / `CardStatementParser.swift` /
   `StatementImporter.swift` reference (e.g. `StatementError`). **Rule:** stubs must mirror the real
   structs' stored properties (copy the declarations from `BankSync.swift`/`Models.swift`, strip
   methods/Codable conformances you don't need). If a parser file imports SwiftUI-only types, exclude
   that file from the harness rather than stubbing UI.
3. Compile set (start here, adjust from compiler errors):
   `swiftc -O Stubs.swift ../../Nidhi/Statements/PDFTableReader.swift ../../Nidhi/Statements/StatementParsers.swift ../../Nidhi/Statements/CardStatementParser.swift main.swift -o harness`
   `StatementImporter.swift` likely pulls in Vision/UIKit — only include it if it compiles cleanly;
   otherwise replicate its routing logic (~10 lines: locked check → `isCombinedHDFC` →
   `CardStatementParser.parse` → `StatementParser.parse`) inside `main.swift` with a comment saying it
   mirrors `StatementImporter.parse`.
4. `main.swift`: for each PDF in `fixtures/` (the four real statement PDFs already live in
   `tools/parser-harness/fixtures/`, gitignored via `*.pdf`: `0036XXXXXXXXXX27_18-06-2026_555.pdf`,
   `Axis atlas credit card statement.pdf`, `FederalBank2557statement.pdf`, `_260123120039484.pdf`):
   - Unlock with passwords from an optional gitignored `fixtures/passwords.json`
     (`{"filename": "password"}`) — Federal/HDFC PDFs are password-locked (scheme like `SUHA0708`).
   - Run the right parser; emit per-file JSON: `{file, accountMask, txnCount, creditCount, debitCount,
     sumHash, closingReconciles, rewardRows, intlRows, firstDate, lastDate, emiPrefixedMerchants}`.
   - `sumHash` = SHA256 of the sorted `"\(date)|\(amount)|\(merchant)"` lines — detects any regression
     without storing real amounts in git.
5. Expectations mode: `./run.sh --record` writes `expectations.json`; plain `./run.sh` compares and
   prints a diff per field, exits non-zero on mismatch. Record once against the current (post-EMI-fix)
   parser output and commit `expectations.json`.
6. Add an explicit assertion (not just the hash) that **no parsed merchant begins with `"EMI "` unless
   followed by `INTEREST`/`PRINCIPAL`** — this pins bug-042 forever.
7. Update `AGENTS.md` ("Build / run / verify") and `docs/statements-and-import.md` ("Verify with the
   offline harness" section) to reference the script. Note in both: fixtures are local-only.
8. Run `./run.sh`, confirm green, then the canonical `xcodebuild` command from `AGENTS.md` to confirm
   the app still builds (the harness must not have required edits to app sources).

## Edge cases a weaker model would miss

- **Do not modify parser sources to make the harness compile.** If a type is missing, stub it; if a file
  won't compile standalone (UIKit/Vision imports), exclude it and replicate only its routing.
- **The statement PDFs must never be tracked by git** — verify with `git ls-files | grep -i pdf`
  (must be empty); `*.pdf` is globally gitignored.
- **HDFC combined + new Federal statements have fragmented glyph coordinates** — the parser may
  legitimately skip txns and only import the account when reconciliation fails. `closingReconciles:
  false` with `txnCount: 0` is a *valid* expectation, not a harness bug.
- **`Date()` fallbacks are banned in parsers** (statement-date conflict system): the harness output must
  not vary between runs. If two `--record` runs differ, a parser is stamping "today" somewhere — that's
  a real bug, log it to `.wolf/buglog.json`, don't paper over it in the harness.
- Tolerant expectations for reward parsing: HDFC per-row rewards are verified on ~53/95 rows, ICICI is
  best-effort. Assert exact counts from the recorded run, but comment in `expectations.json` docs that
  reward counts < txn counts is expected.
- `swiftc` invocation: quote every path (checkouts may live under a path with spaces) in `run.sh`.

## Acceptance criteria

- [ ] `bash "tools/parser-harness/run.sh"` exits 0 and prints one PASS line per fixture PDF.
- [ ] Reverting the EMI-fix hunk in `CardStatementParser.swift` and re-running makes the harness FAIL
      (the EMI assertion and/or `sumHash` mismatch), and restoring it passes again.
- [ ] `git ls-files` contains no `*.pdf` and no `passwords.json`; `expectations.json` contains no
      rupee amounts, account numbers, or merchant names (hashes/counts/masks only — mask = last 4 ok).
- [ ] The pending `CardStatementParser.swift` diff is committed unmodified.
- [ ] `xcodebuild` app build still succeeds (no app-source changes needed by the harness).
- [ ] `AGENTS.md` + `docs/statements-and-import.md` describe the new command.
