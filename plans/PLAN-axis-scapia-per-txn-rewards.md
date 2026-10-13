# PLAN: Parse per-transaction rewards for Axis Atlas (and Scapia if present)

**Rank: 5 of 5.** When per-txn rewards shipped (PR #11), Axis and Scapia per-row rewards were left
unparsed with the note "no sample". A real sample now exists: `Axis atlas credit card statement.pdf`
sits in the repo root (gitignored; move it to the harness fixtures per PLAN-parser-regression-harness).
HDFC shows "Reward Points" per txn; Axis rows should show "EDGE Miles". This closes the reward-capture
gap and feeds the existing InsightsView "International & rewards" card.

**Dependency:** do PLAN-parser-regression-harness first — it gives you the one-command verify loop this
plan needs. Do not attempt this with ad-hoc scripts.

## Goal

`CardStatementParser.parseAxis` emits `reward`/`rewardCurrency` per transaction row where the statement
prints an EDGE Miles figure, verified against the real PDF via the harness. If the Scapia statement
(`FederalBank2557statement.pdf` is the *bank* statement — check whether a Scapia card PDF exists among
the fixtures; if not, Scapia is out of scope, note it and stop there).

## Files to touch

- [Nidhi/Statements/CardStatementParser.swift](Nidhi/Statements/CardStatementParser.swift) — `parseAxis`
  (lines ~121-192). Reward unit already exists: `rewardUnit(.axis)` → "EDGE Miles" (~line 323).
- `tools/parser-harness/expectations.json` — re-record after the change (`--record`), diff by hand.
- [docs/statements-and-import.md](docs/statements-and-import.md) — one line updating reward coverage.
- `.wolf/memory.md` — append what the Axis reward column actually looks like (future samples).

## Implementation order

1. **Dump first, code second.** Write nothing until you've printed the Axis PDF's text layer AND
   `PDFTableReader.words` x/y for the transaction pages (small Swift+PDFKit script, or add a `--dump
   <file>` flag to the harness `main.swift` — prefer the flag, it's reusable). Identify where EDGE Miles
   appear: a per-row trailing integer column, a separate "EDGE Miles summary" table, or both.
2. Read the existing `parseAxis` row loop (~121-192). PR #12 already split the MCC category column and
   forex leg there — the reward figure must be extracted *without disturbing* those captures. Note which
   regex consumes the row tail; rewards are likely an integer column adjacent to the amount, exactly the
   kind of token the merchant-cleanup regexes currently swallow.
3. Extract the reward integer into `SyncedTxn.reward` + `rewardCurrency = rewardUnit(.axis)`, mirroring
   the HDFC pattern at ~line 89-110 (the `"+ N C amt"` handling) — same field semantics, tolerant: rows
   without a figure get nil, never 0.
4. Re-run the harness. Compare: txnCount, sumHash, forex/intl counts MUST be identical to the recorded
   expectations; only `rewardRows` for the Axis file may change. If sumHash moved, your regex ate part
   of a merchant or amount — fix before proceeding.
5. Re-record expectations, update the Axis `rewardRows` count, commit. Update the docs line + wolf
   memory note.
6. Scapia: only if a Scapia *card* statement PDF is available among fixtures, repeat steps 1-5 for
   `parseScapia` (~line 220), unit "Scapia Coins". Otherwise write "Scapia: still no sample" in the
   docs line and stop.

## Edge cases a weaker model would miss

- **Axis prints reward *accrual and reversal*** on many card statements (miles reversed on refunds).
  A refund row's miles should be captured as negative only if the statement prints them signed;
  otherwise leave reversal rows nil rather than guessing sign from the txn sign.
- **Not every row earns miles** (fees, EMI, rent, wallet loads are typically excluded earners). Expect
  rewardRows < txnCount; do NOT loosen the regex until every row matches — false positives (capturing a
  reference number as miles) are worse than gaps. HDFC precedent: 53/95 rows was accepted as correct.
- **The forex leg extraction from PR #12 shares the row tail.** An international row can have BOTH a
  forex figure and a miles figure — verify at least one such row parses both correctly (the PDF has
  international rows; PR #12 was verified on 9 of them for HDFC — check Axis's count in your dump).
- **Milestone/bonus miles rows** ("EDGE Miles earned on achieving...") may appear as non-transaction
  table rows — they must not create phantom txns; if the current row regex already skips them, leave it.
- If the reward integer sits in its own x-column but the text layer concatenates it into the narration,
  prefer whichever source (`pages` words vs text) `parseAxis` already uses — don't mix sources for one
  field mid-parser.
- Per-txn reward capture must NOT touch the account-level reward balance logic (`cardAccount`, ~284) —
  that was an explicit design decision in PR #11.

## Acceptance criteria

- [ ] Harness green: Axis fixture txnCount/sumHash/forex counts unchanged from pre-change recording;
      `rewardRows > 0` and the count matches a manual count of miles-bearing rows in the PDF dump
      (write the manual count in the commit message).
- [ ] Spot-check 3 rows by hand (one domestic earner, one non-earner, one international if present):
      reward value and unit "EDGE Miles" correct, merchant text unchanged vs before.
- [ ] In-app: importing the Axis statement shows star reward chips on Axis txn rows and the Insights
      "International & rewards" card lists EDGE Miles.
- [ ] No changes to parseHDFC/parseICICI outputs (harness hashes identical for their fixtures).
- [ ] App build green; docs + `.wolf/memory.md` updated.
