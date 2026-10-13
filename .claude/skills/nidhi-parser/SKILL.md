---
name: nidhi-parser
description: Work on statement/email parsers in Nidhi — dump a PDF's layout, run the offline swiftc harness, and follow the parser gotchas. Use for any change to StatementParsers, CardStatementParser, PDFTableReader, StatementImporter, or EmailTransactionParser.
---

# Parser workflow (Nidhi)

**Never edit a parser before dumping the input.** No `pdftotext`/poppler here — use Swift+PDFKit.

## 1. Dump the PDF first

If `tools/parser-harness/` exists, use its runner/`--dump`. Otherwise write a throwaway script in the
scratchpad that prints, per page: `page.string` (text layer) AND `PDFTableReader.words` (text + x/y).
Locked PDFs: passwords follow schemes like `SUHA0708`; ask the user or check
`tools/parser-harness/fixtures/passwords.json` (gitignored).

## 2. Verify with the offline harness — not the app

Compile the real parser files unmodified + `PDFTableReader.swift` + stub DTOs
(`SyncedAccount/SyncedTxn/ImportResult/Deposit` copied from `BankSync.swift`, methods stripped) + a
`main.swift`, with `swiftc -O`, and run against the real PDF. Assert: account fields, txn count,
signs, and that reconstructed closing **reconciles** to the stated closing balance.
If `tools/parser-harness/run.sh` exists: run it before AND after your change; only intended
expectation fields may differ.

## 3. Binding rules

- **Never fall back to `Date()`** for an unparseable date — carry the last good date forward and set
  `dateResolved=false` (feeds the conflicts system). Same spirit for amounts (`amountResolved`).
- **Skip txns rather than import wrong amounts** — if the balance chain doesn't reconcile, return the
  account with 0 txns (imports must still return accounts; sparse statements create the account).
- Stable `externalId`s (`fed:<tranId>:<bal>`, `cc:…`) — dedup depends on them; never derive them from
  anything nondeterministic.
- HDFC combined + newer Federal PDFs have fragmented glyph coordinates — prefer the text layer +
  running-balance signing there; coordinate clustering works for the others.
- HDFC card rows: `"EMI "` prefix is an *eligible-for-EMI* marker, not the merchant — stripped unless
  followed by INTEREST/PRINCIPAL. Don't regress this (bug-042).
- Email HTML (`EmailTransactionParser`): decode numeric entities (`&#8202;`) and normalise ALL unicode
  spaces before regexing, or Amount/Merchant extraction silently returns nil.
- Never commit real PDFs, real amounts, or account numbers (masks/last-4 are fine). `*.pdf` is
  gitignored — keep it that way.

## 4. Afterwards

Log the fix to `.wolf/buglog.json`, update `docs/statements-and-import.md` if behaviour changed, and
re-record harness expectations only after hand-verifying the diff.
