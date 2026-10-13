# Getting started

## Install & first launch

Nidhi is a personal, open-source app — you build it yourself with Xcode 26+ onto an iOS 26
device or simulator (see the repo `README.md` for the build command). On first launch the app seeds a
default set of budget categories, a net-worth milestone ladder, and badge slots. Everything else starts
empty until you add accounts or import data.

## The six tabs

| Tab | What lives there |
|-----|------------------|
| **Home** | Net-worth headline, monthly budget bar, recent transactions, trends |
| **Plan** | Budget categories: caps vs actual spend, period navigation, drill-in |
| **Insights** | Spending breakdowns, international spend & card rewards |
| **Goals** | Savings goals ("quests"), badges, milestones |
| **Wealth** | Investments, deposits, net-worth composition and milestone ladder |
| **Income** | Income streams, payslips, and the tax estimate |

**Accounts** (banks, credit cards, deposits) are managed from the accounts screen, and app-wide
options live in **Settings** (backup, Gmail, AA sync, AI, conflicts, imported statements, re-scan
categories, clear all data).

## Three ways to get your data in

1. **Import a statement PDF** — the fastest way to bootstrap an account with history.
   See [Importing statements](importing-statements.md).
2. **Connect Gmail (read-only)** — the app scans transaction-alert emails and statement attachments
   and keeps itself up to date automatically. See [Gmail & bank sync](gmail-and-bank-sync.md).
3. **Log manually** — add accounts and transactions by hand; useful for cash spending.

These combine safely: alerts and statements about the same transaction are de-duplicated, and a
statement *enriches* an alert-created transaction rather than duplicating it.

## A suggested first hour

1. Import your latest bank statement PDF (enter its password when asked — it's remembered securely).
2. Import your credit-card statements — cards, limits, rewards and international spend appear.
3. Open **Plan** and set realistic caps on your top 5 categories.
4. Create one goal in **Goals** and back it with a deposit or investment so it tracks itself.
5. In Settings, check **Auto-backup** is on.
