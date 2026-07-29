# Gmail & bank sync

## Gmail auto-import (read-only)

Connect your Gmail with Google's standard sign-in (OAuth + PKCE, `gmail.readonly` scope — the app can
never send, delete, or modify mail). Tokens are kept in the iOS Keychain. Building your own copy of the
app requires a free Google OAuth client ID — see the repo README.

Two scans run, on demand and periodically in the background:

1. **Transaction alerts** — bank/card alert emails (HDFC, ICICI, Axis, Scapia/Federal RuPay, …) become
   transactions within minutes of a purchase. That covers UPI, NEFT/IMPS transfers, debit-card and
   ATM withdrawals, credit-card spends and refunds, **salary credits**, and **standing-instruction
   auto-debits** such as loan EMIs, card autopay and RD instalments. Daily "available balance" emails
   become dated balance anchors, so your balance tracks even between statements.

   Mail that quotes money but moves none — OTPs, declined payments, "will be debited" reminders,
   mandate registrations and statement notices — is ignored, so nothing phantom lands in your ledger.
2. **Statement attachments** — statement PDFs attached to emails are imported automatically, using
   your vaulted passwords. Locked ones queue under Settings → **Needs password**.

A processed ledger guarantees a re-scan never re-imports something twice.

## Account Aggregator (Setu)

Optional RBI Account Aggregator sync: link accounts through the AA consent flow and pull transactions
directly from the bank rails. Requires your own Setu credentials (see README); off by default.

## How sources reconcile

Alerts are fast but thin; statements are slow but authoritative. The app merges them:

- Same account + amount + sign within a few days → one transaction, statement details win.
- Balance readings only ever move the anchor **forward in time** — a stale email or old statement can
  never clobber a newer reading.
