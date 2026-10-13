# Integrations

All integrations are opt-in and run on-device. Secrets live in the Keychain (`Keychain.swift`).

## Gmail (read-only) — `GmailManager.swift`, `GmailProvider.swift`, `GmailBackground.swift`

- OAuth 2.0 + **PKCE**, scope `gmail.readonly`. Public iOS client id from `Info.plist` (`GIDClientID`);
  no client secret. The web step uses `ASWebAuthenticationSession` (anchor: `nidhiPresentationAnchor()`).
  Tokens are stored in the Keychain.
- **Two scans**: transaction-alert emails (`EmailTransactionParser.swift`) and statement-PDF attachments
  (routed through `StatementImporter`). Background refresh via `BGTask` (`…gmailrefresh`, `…stmtrefresh`).
### Alert coverage — `EmailTransactionParser`

Patterns are derived from a survey of real alert mail (2018 – 2026) rather than guessed. Every issuer
re-words its alerts every year or two **while keeping the same subject line**, so matching is on the
body, ordered most-specific-first, grouped per issuer, and retired wordings are kept because
backfilling old mail depends on them.

| Issuer | Covered |
|---|---|
| HDFC bank a/c | UPI debit ×3 eras, UPI credit ×3 eras, **standing-instruction auto-debits** (loan EMI, own/other-bank card autopay, RD instalment), **deposit & salary credits** ×3 eras, IMPS ×2, NetBanking transfers/NEFT/bill payments ×5, card-bill payment |
| HDFC debit card | POS ×2 eras, ATM withdrawal |
| HDFC credit card | spend, refund/reversal, e-mandate charge |
| Federal / Scapia | card spend (plain + both rewards variants, capturing the reward count), fuel-surcharge waiver, refund, bill repayment |
| ICICI card | spend ×3 eras, bill payment ×2 eras, merchant refund |
| Axis card | labelled spend + reversal, prose spend ×2 eras, prose reversal |

Two invariants make this safe:

- **Sender gate.** Only known bank alert senders may mint a transaction (`bankCode(fromSender:)`),
  with a denylist for the issuers' marketing sub-domains. The Gmail query also matches on content
  keywords, so without the gate any newsletter quoting "has been debited" could book money.
- **Negative guards first.** `isNonTransactional` rejects OTPs, declines, pre-debit intimations,
  mandate registrations, statement notices and service mail before any positive pattern runs — they
  all quote an amount, a merchant and a card number.

Deliberately **not** parsed, because the money is already counted elsewhere or the mail is
insufficient: prepaid-wallet spends (ICICI FASTag tolls, HDFC Foodplus — the wallet load already
debited a tracked account), BillDesk "payment processed" mail (arrives again as the HDFC SI debit),
ICICI standing-instruction receipts (the plain card alert fires seconds earlier for the same charge),
and foreign-currency card alerts (they state only the foreign amount — the card statement is the only
source of the INR value).

**Gotchas that cost real transactions:**

- `from:axisbank` does **not** match `alerts@axis.bank.in`. Both spellings must be in
  `GmailProvider.query`; when Axis migrated domains, every Axis alert silently stopped being fetched.
- A debit-card alert quotes the **card's** last-4, which differs from the account's. It is emitted
  with an empty mask + `bankCode` and resolved by `Store.accountName(forMask:source:bankCode:)`, so
  the spend lands on the real account instead of minting a phantom one per card.
- `GmailManager.parserVersion` gates a one-time processed-ledger bypass. **Bump it whenever the
  parser learns a format** — every scanned message id is marked processed even when parsing returned
  nil, so without a bump the newly-parseable history stays invisible forever. Stable `gmail:<id>`
  externalIds keep the re-merge idempotent.
- HDFC renders `Rs. INR 7,43,983.38` in the HTML but Gmail's own text extraction of the *same* mail
  drops a comma (`7,43983.38`) — amount patterns must tolerate both groupings.
- The **scan window bounds the backfill**. Patterns for wordings a bank retired years ago are dead
  code unless the window reaches them, so the "Look back" picker goes up to *All mail* and the
  listing ceiling scales with the window (Gmail lists newest-first, so a fixed cap would re-read the
  same newest N forever).
- A support reply (`customer.service@axisbank.com`) quotes the customer's original alert underneath
  the agent's text. Support/no-reply/statement mailboxes are therefore denylisted alongside the
  marketing sub-domains, or the quoted alert books the spend a second time.
- An account resolved from an alert can be **unattributable** (an issuer the user holds no account
  for). `Store.accountName` returns nil and the row is dropped: attributing it to "the first
  account" books one issuer's spend against another's balance, and a card charge landing on a bank
  account permanently corrupts an anchored balance, since that balance re-derives from its rows.
- **Processed-statement ledger**: handled statement keys (`messageId:attachmentId`) persist in
  `gmail_done_stmts`; a scan skips anything already in `pending` **or** `processed`, marks success/dismiss
  as processed, and de-dups `pending` on load. This prevents duplicate re-imports and pending pile-up.
  `importPending` (user enters a PDF password) imports, vaults the password, and marks processed.
  "Clear all data" clears the ledger.

## Account Aggregator (Setu) — `BankSync.swift`, `SetuAAClient.swift`, `SyncManager.swift`, `BankSyncUI.swift`

- **Off by default** (`accountAggregatorEnabled`). When enabled, connects banks via Setu AA with a consent
  web step; `SetuAAClient` calls the API with `x-client-id`/`x-client-secret` (entered in Settings, stored
  in Keychain). `RebitFI.parse` reads the ReBIT-standard FI JSON defensively into `SyncedAccount`/`SyncedTxn`.
- A mock/no-network path exists for development.

## Market data

- `QuoteProvider.swift` — Yahoo Finance (stocks/ETFs) + AMFI (mutual fund NAV). See [investments.md](investments.md).
- `FXProvider.swift` — currency rates from a public endpoint (`Store.fxRates`).

## Device

- `Notifications.swift` — local notifications (`notificationsEnabled`).
- `LiveActivity.swift` + `NidhiWidgets/` — widgets / Live Activity surfaces.
- `NidhiApp.swift` — registers BG tasks and injects `Store`.
