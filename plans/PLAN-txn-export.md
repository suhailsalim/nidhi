# PLAN: Transaction export (CSV / JSON share sheet)

**Missing-feature rank: 5 of 10.** The app can back up its whole blob, but there's no way to get
*transactions* out in a form a spreadsheet, accountant, or tax tool can read. For an open, no-lock-in
app this is a philosophical gap as much as a practical one. Small, self-contained feature.

## Goal

Export the current (possibly filtered) transaction list — or everything — as CSV or JSON via the iOS
share sheet, plus a full-data export entry in Settings.

## Files to touch

- **Create** `Nidhi/TxnExporter.swift` — pure functions `csv(_ txns:[Txn]) -> Data` and
  `json(_ txns:[Txn]) -> Data`.
- [Nidhi/UI/Sheets.swift](Nidhi/UI/Sheets.swift) — export button (share icon) on
  `TransactionsSheet`'s toolbar exporting *what's currently filtered*; Settings row "Export
  transactions (CSV)" exporting all.

## Implementation order

1. `TxnExporter.csv`: columns `date,merchant,category,account,amount,currency,tags,counterparty,
   transfer,reward,rewardUnit,forexAmount,forexCurrency,source`. RFC-4180 quoting (quote fields
   containing `,`/`"`/newline, double inner quotes). Dates ISO-8601 (`yyyy-MM-dd`), amounts plain
   `-1234.56` (no ₹, no thousands separators — Excel-safe). UTF-8 **with BOM** so Excel renders ₹ and
   Indian merchant names correctly.
2. `json`: `JSONEncoder` with `.iso8601` dates + `.prettyPrinted`, encoding a dedicated lightweight
   DTO (not the persisted `Txn` coding — you don't want persistence's tolerant CodingKeys entangled
   with an export format).
3. Share: write to a temp file named `transactions-YYYYMMDD.csv` (share sheets need a file URL for a
   proper filename/UTI), present `ShareLink`/`UIActivityViewController` per existing app patterns —
   check how BackupManager/Settings already share files and reuse that mechanism.
4. Wire the toolbar button (exports respect current search/filter) and the Settings row.

## Edge cases a weaker model would miss

- **Merchant names contain commas and quotes** (statement narrations certainly do) — the quoting rule
  is where naive CSV breaks; test with a merchant containing `", Ltd"`.
- **Excel + UTF-8**: without a BOM, ₹ and Devanagari mojibake in Excel; with it, Numbers/Sheets are
  fine too.
- Amounts must not be locale-formatted (`1,234.56` breaks CSV columns) — format with
  `String(format: "%.2f")`, never a currency formatter.
- Tags is a list — join with `|` inside one field, not commas.
- Temp file cleanup: write into `FileManager.temporaryDirectory` and let iOS purge it; don't litter
  Documents (that's the backup's home and it's user-visible in Files).
- This is an **outward-facing data flow** — but it's user-initiated via the share sheet, so no
  confirmation needed beyond the share UI itself. Do not auto-write exports anywhere.

## Acceptance criteria

- [ ] Export from a filtered list contains exactly the visible rows; Settings export contains all.
- [ ] CSV opens correctly in Numbers and Google Sheets: ₹-containing merchants intact, comma-containing
      merchants in one cell, amounts numeric.
- [ ] JSON round-trips through `JSONDecoder` with the DTO.
- [ ] Rewards/forex columns populated for card-statement rows that have them, empty otherwise.
- [ ] Build green.
