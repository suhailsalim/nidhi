# PLAN: Project website (landing page + hosted docs)

## Goal

A public website for the app with two parts, both served from GitHub Pages (free, no backend —
matching the project's no-server ethos):

1. **Landing page** at the site root — what the app is, the privacy pitch, screenshots, build-it-yourself
   instructions, and a link to GitHub.
2. **Docs** at `/docs/` — the MkDocs site that already exists in this repo (`mkdocs.yml` +
   `docs/`), published automatically on push.

No trackers, no analytics, no cookies — the site must be able to say "this page collects nothing"
truthfully, because that's the app's core selling point.

## Files to touch

- **Create** `website/index.html` — a single self-contained landing page (inline CSS, no JS frameworks,
  no CDN fonts — system font stack; matches the `Zen` palette from `Nidhi/UI/Theme.swift`; read that
  file and reuse its hex colours).
- **Create** `website/screenshots/` — placeholder frames now; real simulator screenshots later
  (capture with `xcrun simctl io booted screenshot`; NEVER screenshots containing real financial data —
  seed demo data first).
- **Create** `.github/workflows/site.yml` — GitHub Actions: on push to `main`, `pip install
  mkdocs-material && mkdocs build --strict -d _site/docs`, copy `website/*` to `_site/`, deploy via
  `actions/deploy-pages`.
- **Edit** `mkdocs.yml` — set `site_url` once the Pages URL exists; keep `repo_url` accurate.
- **Edit** `README.md` — add the site link at the top.

## Implementation order

1. Read `Nidhi/UI/Theme.swift` for the Zen palette hex values and typography feel.
2. Build `website/index.html`. Sections, in order:
   - Hero: app name + one-liner ("Your money, entirely on your device") + privacy badges
     (No backend · No analytics · Open source).
   - Feature grid (6 cards): statement import, Gmail auto-import, budgets, goals backed by real
     assets, investments with live prices, Indian tax engine. Pull copy from `docs/index.md` — do not
     invent new claims.
   - Privacy section: verbatim-adapt `docs/guide/backup-and-privacy.md`'s "Privacy summary".
   - "Build it yourself": requirements + the `git clone` / open-in-Xcode steps from `README.md`
     (this app is sideloaded/self-built; do NOT imply an App Store listing).
   - Footer: GitHub, docs link, license, "not affiliated with any bank/Google/Yahoo/AMFI/Setu"
     disclaimer (copy from README).
3. Dark mode via `prefers-color-scheme` (the app is design-forward; the site should be too).
4. Workflow: standard Pages deploy. `mkdocs build --strict` must pass — fix any broken doc links it
   reports rather than dropping `--strict`. Known issue: dev docs link to `../AGENTS.md` (outside
   `docs_dir`) — convert those links to the GitHub blob URL so strict mode passes.
5. Enable Pages (Actions source) in repo settings — this is a manual step; list it in the PR
   description for the user.
6. Verify: workflow green, landing page renders on mobile width (390px) and desktop, `/docs/` serves
   the MkDocs site, zero external requests in the browser network tab (fonts/CSS/JS all inline/local).

## Edge cases a weaker model would miss

- **Repo name/URL**: confirm the actual GitHub remote (`git remote -v`) before hardcoding Pages URLs;
  `mkdocs.yml` currently guesses `suhailsalim/nidhi`.
- **`site/` is gitignored** — the workflow builds into `_site/` in CI; never commit build output.
- **No real data anywhere**: screenshots must come from a demo-seeded simulator; audit every image for
  masked-but-real account numbers before committing.
- **`--strict` + `exclude_docs`**: `docs/README.md` is excluded from the site; any nav or page linking
  to it will fail strict builds — link to GitHub instead.
- If the app is renamed (see the naming proposal), the site copy takes the new name but the repo,
  bundle id, and `site_name` migrate in a separate coordinated change — don't half-rename.

## Acceptance criteria

- [ ] `mkdocs build --strict` passes locally (`pip install mkdocs-material`).
- [ ] Pages deploy workflow green; `/` shows the landing page, `/docs/` the documentation.
- [ ] Browser devtools on the landing page: zero third-party/network font/script requests.
- [ ] Landing page lighthouse-usable on mobile (no horizontal scroll at 390px).
- [ ] All copy matches claims already made in README/docs — nothing new invented.
