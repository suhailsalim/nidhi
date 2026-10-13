# Nidhi — निधि

*(formerly "Nidhi" — code names, targets and bundle id keep the old name)*

**[Website](https://suhailsalim.github.io/win-the-money/)** · **[Docs](https://suhailsalim.github.io/win-the-money/docs/)**
*(site not yet published — see [`plans/PLAN-website.md`](plans/PLAN-website.md) for status)*

A private, on-device personal-finance tracker for iOS — built in SwiftUI for Indian banking
(₹/INR-first). It tracks **net worth, bank & card balances, transactions, budgets, fixed/recurring
deposits, stocks/ETFs/mutual funds, goals, income & tax**, and can pull statements & alerts straight
from your own Gmail and bank PDFs — entirely on your device.

> **Status:** personal project, open-sourced. No warranty. Not affiliated with any bank, Google,
> Yahoo, AMFI, or Setu. See [Privacy](#privacy) and [Disclaimer](#disclaimer).

## Highlights

- **Net worth & wealth** — banks + cards + deposits + investments, with history and milestones.
- **Statement import** — password-protected bank/card statement PDFs (HDFC, Federal, Axis, ICICI, …)
  parsed on-device, including combined statements with multiple accounts + FDs/RDs.
- **Gmail auto-import** — read-only OAuth scan of transaction alert emails and statement attachments.
- **Smart categorisation** — a fuzzy, expandable merchant→category library (regex + normalisation).
- **Investments** — live prices/NAV from Yahoo Finance (stocks/ETFs) and AMFI (mutual funds), with
  buy-more averaging.
- **Budgets, goals, income & tax**, plus light gamification (XP, levels, badges, milestones).
- **No backend, no third-party SDKs.** All data is local; secrets live in the iOS Keychain.

## Requirements

- Xcode 26+ / iOS 26 SDK
- An iOS 26 device or simulator
- (Optional) A Google Cloud OAuth **iOS client ID** for Gmail import
- (Optional) Setu Account Aggregator credentials for AA bank sync

## Build & run

```bash
# open in Xcode
open Nidhi.xcodeproj

# …or build for a simulator from the CLI
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Nidhi.xcodeproj -scheme Nidhi \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -allowProvisioningUpdates build
```

It builds against a free personal Apple team; set your own team/bundle id in the target.

### Gmail import setup (optional)

Gmail import needs a Google OAuth **iOS** client ID (public client + PKCE — there is no client secret).

1. Create an OAuth client in Google Cloud Console (type: iOS), using this app's bundle id.
2. In `Info.plist`, replace the two `YOUR_GOOGLE_OAUTH_CLIENT_ID` placeholders with your client id —
   once under `GIDClientID`, once in the reversed-DNS `CFBundleURLSchemes` entry.
3. To keep your local client id out of commits: `git update-index --skip-worktree Info.plist`.

The Gmail scope is read-only (`gmail.readonly`). Tokens are stored in the Keychain, never in code.

## Privacy

- **Everything is on-device.** There is no server, analytics, or telemetry.
- Network calls are only to: Google (Gmail, your account), Yahoo Finance & AMFI (public quotes/NAV),
  Setu (only if you explicitly enable Account Aggregator), and a public FX endpoint.
- Statement PDF passwords and OAuth/Setu secrets are kept in the **iOS Keychain**.
- Backups you export do **not** include secrets.

## Architecture & docs

- [`AGENTS.md`](AGENTS.md) — build/run, architecture, conventions, gotchas (for humans and AI agents).
- [`docs/`](docs/) — one document per feature area.
- [`CLAUDE.md`](CLAUDE.md) — entry point for Claude Code / AI agents (points at `AGENTS.md`).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributions welcome — especially additional bank/card
statement parsers and merchant-catalog entries.

## License

[GPL-3.0](LICENSE). © contributors.

## Disclaimer

This app is for personal money tracking only. It is **not** financial advice, and parsed figures
(balances, transactions, P&L, tax estimates) may be inaccurate — always verify against your bank.
Trademarks (bank, card, and merchant names) belong to their respective owners and are used only for
factual identification; no bank artwork is bundled.
