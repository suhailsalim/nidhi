# AGENTS.md — Nidhi

Guidance for humans and AI coding agents working in this repo. Read this first; it exists to prevent
re-deriving the architecture from scratch every session. Feature deep-dives live in [`docs/`](docs/).

## What this is

A private, **on-device** SwiftUI personal-finance app for iOS 26 (₹/INR-first, India). No backend,
**no third-party dependencies**, no analytics. All data is local JSON; secrets live in the Keychain.

## Build / run / verify

```bash
# Build for simulator (the canonical command):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Nidhi.xcodeproj -scheme Nidhi \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$(cat /tmp/nidhi_sim.txt)" \
  -derivedDataPath build/dd -allowProvisioningUpdates build 2>&1 \
  | grep -iE "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"
```

- `/tmp/nidhi_sim.txt` holds a booted simulator UDID (or use `-destination 'platform=iOS Simulator,name=iPhone 16 Pro'`).
- Free personal Apple team `WNU93FA79R`, bundle `com.suhail.Nidhi`.
- There is **no unit-test target.** Parsers are verified with an **offline PDFKit harness**: compile the
  real parser file(s) + `PDFTableReader.swift` + small stub model types + a `main.swift` with `swiftc`,
  then run it against a real PDF. See [`docs/statements-and-import.md`](docs/statements-and-import.md).
- No `pdftotext`/poppler available; dump a PDF's text/words with a small Swift+PDFKit script.

## Architecture in one screen

- **`Store` (`Nidhi/State/Store.swift`) is the single source of truth** — an `ObservableObject` holding
  every `@Published` collection and all derived totals + mutations. Views are thin and read/write `Store`.
  Published state: `categories, txns, banks, cards, deposits, goals, milestones, badges, investments,`
  `incomeStreams, loans, merchantRules, fxRates, nwHistory`, plus settings/profile fields. The loans
  surface (net worth, EMI linking) lives in `Store+Loans.swift`; its amortisation maths is the pure,
  `Date()`-free `LoanMath.swift`.
- **Models** (`Nidhi/State/Models.swift`): `BudgetCategory, Txn, TxnSource, BankAccount, CreditCard,`
  `Deposit, InvestmentKind, Investment, Goal/GoalStatus, Loan/LoanAdjustment, Milestone, Badge,`
  `IncomeStream, PlanMonth, Segment, Tab, Currencies`. Plain `Codable` structs.
- **Persistence** (`Nidhi/State/Persistence.swift`): one `Persist` blob in UserDefaults; **tolerant**
  custom `init(from:)` per model. **RULE:** new stored properties must decode with a default — never
  let decoding throw. See the file header and [`docs/persistence-and-backup.md`](docs/persistence-and-backup.md).
- **UI**: `RootView.swift` is a 6-tab `TabView` → `HomeView, PlanView, InsightsView, GoalsView,`
  `WealthView, IncomeView`. `AccountsView` manages banks/cards. `Sheets.swift` holds most add/edit
  sheets and Settings. `Components.swift` + `Theme.swift` (`Zen` palette) are the design system.
- **Entry**: `NidhiApp.swift` (`@main`), injects `Store`, runs background tasks.

## File map (by folder)

Sources live in folders under `Nidhi/` (the Xcode project uses file-system-synchronized
groups, so the folder tree IS the project structure — add/move files on disk and Xcode follows):

| Folder | Contents |
|--------|----------|
| `App/` | `NidhiApp.swift` (@main), `RootView.swift` (6-tab TabView) |
| `State/` | `Store.swift` (single source of truth), `Models.swift`, `Persistence.swift`, `BackupManager.swift` |
| `UI/` | Tab views (`HomeView/PlanView/InsightsView/GoalsView/WealthView/IncomeView.swift`), `AccountsView.swift`, `Sheets.swift` (add/edit sheets + Settings), `Components.swift` + `Theme.swift` (Zen design system), `BankSyncUI.swift`, `AIView.swift` |
| `Statements/` | `StatementImporter.swift` (routing + OCR), `StatementParsers.swift` (bank), `CardStatementParser.swift` (cards), `PDFTableReader.swift`, `SpreadsheetImporter.swift`, `StatementVault.swift`, `StatementBackground.swift` |
| `Gmail/` | `GmailManager.swift`, `GmailProvider.swift`, `GmailBackground.swift`, `EmailTransactionParser.swift` |
| `AccountAggregator/` | `BankSync.swift` (import DTOs), `SetuAAClient.swift`, `SyncManager.swift` |
| `Income/` | `TaxEngine.swift` (slab estimate, both regimes), `PayslipParser.swift` |
| `AI/` | `AI.swift` (multi-provider `AIManager`), `AIInsights.swift` (aggregate-only summary) |
| `Catalogs/` | `BankCatalog.swift`, `CardCatalog.swift`, `BrandCatalog.swift` (+ `Store.classify`), `MarketCatalog.swift` |
| `Market/` | `QuoteProvider.swift` (Yahoo/AMFI), `FXProvider.swift` |
| `Platform/` | `Keychain.swift`, `Notifications.swift`, `LiveActivity.swift` |
| `Intents/` | `AppIntents.swift` (Siri read intents + phrases), `QuickLogStore.swift` (inbox drain into `Store`) |

Top level: `Assets.xcassets` + `Nidhi.entitlements` stay at `Nidhi/` root (referenced by
explicit path). `Shared/` (widget snapshot + `QuickLog.swift`, compiled into both targets — NOT a synchronized
group, so a new file there needs a pbxproj entry) and `NidhiWidgets/` are separate targets;
`Info.plist` / `NidhiWidgets-Info.plist` sit at repo root (pbxproj paths). Other repo dirs:
`docs/` (MkDocs: user guide + dev docs), `plans/` (execution plans, see `plans/README.md`),
`design/` (icons + logo sources), `tools/parser-harness/fixtures/` (local-only real statement PDFs,
gitignored), `.claude/skills/` (committed agent skills).

## Conventions

- **INR-first**, `Zen` colours/typography (`Theme.swift`); reuse `Components.swift` (`LabeledField`,
  `LabeledAmountField`, `DeleteSheetButton`, card covers, …) — don't reinvent form rows.
- Catalogs (`BankCatalog`, `CardCatalog`, `BrandCatalog`, `MarketCatalog`) are **factual reference data**
  meant to be expanded; add entries rather than special-casing logic.
- Quotes: Yahoo Finance for stocks/ETFs, AMFI for MFs, a public FX endpoint for currency. Free, no keys.
- Networking is hand-rolled `URLSession`; OAuth/AA web flows use `ASWebAuthenticationSession` (anchor via
  the shared `nidhiPresentationAnchor()` in `GmailManager.swift`).

## Gotchas (read before debugging these)

- **Statement glyph obfuscation:** HDFC combined + new Federal statements have *fragmented/mispositioned*
  PDF glyph coordinates — prefer the **text layer** and reconcile reconstructed txns to a stated closing
  balance; skip txns rather than import wrong amounts.
- **Processed-statement ledger:** `GmailManager` persists handled statement keys (`gmail_done_stmts`) so a
  re-scan never re-imports (duplicates) or re-queues a pending PDF. Don't remove this guard.
- **Import returns accounts even with 0 txns** (`StatementImporter.parse`) — needed so sparse statements
  still create the account.
- **Category re-scan** runs once on a `nidhi_cat_lib_v` bump and via Settings → "Re-scan categories";
  it never overrides manual `merchantRules`.
- **Benign console noise** to ignore: `nw_protocol_instance_set_output_handler … udp`, `CoreGraphics PDF
  has logged an error`, `<decode: bad range …>` — OS/PDFKit logs, not app bugs.

## Open-source hygiene

- Never commit secrets. `Info.plist` ships a `YOUR_GOOGLE_OAUTH_CLIENT_ID` placeholder; real ids/secrets
  live in the Keychain (or a `skip-worktree` local `Info.plist`).
- Use bank/card/merchant names only for **factual identification**. Deliberate exception (2026-07-14):
  small CC0-licensed vector *merchant* marks from [Simple Icons](https://github.com/simple-icons/simple-icons)
  are bundled for common-brand icons (`Assets.xcassets/brand_*.imageset`, wired via `BrandCatalog.icon`) —
  the user explicitly chose this after being shown the trademark/App-Store-review tradeoff. This app ships
  only via the free personal Apple developer team (`WNU93FA79R`), i.e. **not App-Store-distributed**, which
  materially lowers the real-world risk and was the basis for the exception. Do not extend this to bank/card
  **issuer** artwork (logos, hologram art, card face designs) without a fresh explicit decision — the
  exception is scoped to merchant/brand marks only.

## OpenWolf

This repo uses [OpenWolf](https://openwolf.com) — Claude Code middleware that maintains a project map
(`.wolf/anatomy.md`), learned conventions (`.wolf/cerebrum.md`), and a token-aware read layer to cut
re-reads. `.wolf/` is git-ignored; run `openwolf init` once locally, `openwolf scan` after big structural
changes. Treat `.wolf/cerebrum.md` "Do-Not-Repeat" notes as binding.
