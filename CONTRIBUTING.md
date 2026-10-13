# Contributing to Nidhi

Thanks for your interest! This is a SwiftUI / iOS 26 app with **no third-party dependencies**.

## Getting started

1. Read [`AGENTS.md`](AGENTS.md) — it covers the build command, architecture, and the conventions
   that keep the codebase consistent (single `Store`, tolerant persistence, the `Zen` theme, etc.).
2. Browse [`docs/`](docs/) for the feature area you want to touch.
3. Build: see the `xcodebuild` command in the README / `AGENTS.md`.

## Ground rules

- **No new third-party dependencies** without discussion — the app is intentionally self-contained.
- **Persistence is forward/backward compatible.** When you add a stored property, follow the rule in
  [`docs/persistence-and-backup.md`](docs/persistence-and-backup.md) and `Nidhi/State/Persistence.swift`
  (every field decodes with a default — never let decoding throw on a missing key).
- **Keep `Store` the single source of truth.** Views are thin; derived values are computed on `Store`.
- **Match the surrounding style** — comment density, naming, INR formatting, and `Zen` colours.
- **Don't commit secrets.** OAuth/Setu credentials and PDF passwords belong in the Keychain.

## Especially welcome

- **New statement parsers** for banks/cards not yet supported. See
  [`docs/statements-and-import.md`](docs/statements-and-import.md) for the parser pattern and the
  offline PDFKit test-harness approach. Please verify against a real (redacted) statement.
- **Merchant catalog entries** — add `BrandRule`s in `Nidhi/Catalogs/BrandCatalog.swift`
  (see [`docs/transactions-and-categories.md`](docs/transactions-and-categories.md)).
- **Bank/card catalog** entries in `Nidhi/Catalogs/BankCatalog.swift` / `CardCatalog.swift`.

## Pull requests

- Keep PRs focused; describe what you changed and how you verified it (build output, harness run,
  or screenshots).
- Never include real account numbers, balances, or statement files in code, tests, or screenshots.

## License

By contributing you agree your contributions are licensed under [GPL-3.0](LICENSE).
