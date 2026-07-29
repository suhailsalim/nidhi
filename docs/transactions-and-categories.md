# Transactions & categorisation

## Transactions

`Txn` (`Models.swift`) carries merchant, symbol, category, account, signed amount, date, optional
`externalId`/`counterparty`/`statementId`, `tags`, and a `transfer` flag. Transactions arrive from
statement import, Gmail alerts, AA sync, or manual entry, and are deduped by `externalId`.

## Classification chain — `Store.classify(merchant:counterparty:narration:income:)`

In order:
1. **Transfers** (credit-card bill payments, self-transfers) → category `Transfer`, `transfer = true`.
2. **Refunds** (income + refund keywords) → tag `Refund`.
3. **Income** (non-refund credit) → `Income`.
4. **Manual rule** wins next: `merchantRules[ruleKey(counterparty|merchant)]` → that category.
5. **Brand library**: `BrandCatalog.classify(text)` → category + facet tags.
6. **Keyword fallback** → else `Other`.

`Classifier` (in `BrandCatalog.swift`) detects transfers/refunds; `learnMerchant` records a manual rule
and retro-applies it.

## Brand library — `BrandCatalog.swift`

- `BrandRule { patterns: [String]  // case-insensitive regex/substrings; brand; category; tags }`,
  ordered **most-specific-first** (first match wins — e.g. "Amazon … grocery" before generic Amazon).
- `normalize(_)` strips payment rails (UPI/POS/NEFT/UPILITE…), `WWW`, `.com/.in`, ref numbers, and
  glued city/state suffixes so messy statement strings match
  (e.g. `WWW SWIGGY COMGURGAON`, `PZELECTRICITYMUMBAI`, `MC DONALDSCOCHIN`).
- `classify(_)` normalises then regex-matches. **To expand coverage, just add `BrandRule`s** — grouped
  by category in the file. `TagStyle` gives each tag a deterministic colour/icon.

## Root categories

Locked, maintained set in `Store.baseCategories`: Eating out, Online food delivery, Groceries, Transport,
Travel, Fuel, Shopping, Subscriptions, Entertainment, Bills & Utilities, Insurance, Tax, EMI & Loans,
Health, Education, Family, Investments, Other. `ensureBaseCategories` keeps them present; `symbolFor` maps
names to SF Symbols; `migrateRentBills` renamed the legacy "Rent & Bills" → "Bills & Utilities".
Tax splits by facet tag: **"Direct tax"** (CBDT / income tax / OLTAS / ITNS challans / advance &
self-assessment tax — CBDT is the Central Board of Direct Taxes) and **"Indirect tax"** (GST / GSTN /
CGST / SGST / IGST / UTGST, CBIC epayments, and ICEGATE / customs duty).

## Retroactive re-scan — `Store.recategorizeAll()`

Re-runs the library over existing transactions, updating category + tags **only where the library matches**
and **never** overriding manual `merchantRules`, transfers, or income. Runs once automatically when the
`wtm_cat_lib_v` version bumps, and on demand via **Settings → Re-scan categories**.
