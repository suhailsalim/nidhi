# PLAN: App lock (Face ID / passcode) + screen privacy

**Missing-feature rank: 1 of 10.** A finance app holding every transaction and balance has no lock —
anyone with the unlocked phone sees everything. Highest value-to-effort of the missing features, and it
strengthens the app's core privacy identity.

## Goal

Optional biometric lock (Face ID/Touch ID with passcode fallback via `LocalAuthentication`), a blur
overlay in the app switcher, and optional per-launch vs on-background-timeout locking.

## Files to touch

- **Create** `Nidhi/AppLock.swift` — `ObservableObject { isLocked, unlock() }` wrapping
  `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)`.
- [Nidhi/App/NidhiApp.swift](Nidhi/App/NidhiApp.swift) — overlay a lock screen over
  `RootView` when locked; observe `scenePhase` to lock on background and blur in the switcher.
- [Nidhi/UI/Sheets.swift](Nidhi/UI/Sheets.swift) — Settings: "App lock" toggle + "Require after"
  picker (immediately / 1 min / 5 min). Settings via `UserDefaults` keys (`nidhi_lock_on`,
  `nidhi_lock_grace`), not the Persist blob (a lock setting must survive/act independent of data restore).
- `Info.plist` — `NSFaceIDUsageDescription`.

## Implementation order

1. `AppLock.swift`: `isLocked` starts true iff enabled; `unlock()` calls `evaluatePolicy` with reason
   "Unlock your finances"; use `.deviceOwnerAuthentication` (passcode fallback included) not
   `.deviceOwnerAuthenticationWithBiometrics`.
2. App shell: `ZStack { RootView(); if lock.isLocked { LockScreen() } }`; on `scenePhase == .background`
   record the timestamp; on `.active`, lock if grace expired; while `.inactive`/`.background` show an
   opaque `Zen`-styled cover (this is what the app switcher snapshots).
3. Settings UI: enabling the toggle immediately runs one successful auth (prevents locking yourself out
   on a device with no biometrics/passcode — if `canEvaluatePolicy` fails, show why and don't enable).
4. Auto-unlock trigger on appear of the lock screen (Face ID feels instant), plus a manual "Unlock"
   button for retry after cancel.

## Edge cases a weaker model would miss

- **Background tasks must not be blocked by the lock**: Gmail/statement BG refresh
  (`GmailBackground.swift`, `StatementBackground.swift`) runs headless — the lock is UI-only; never
  gate `Store` loading on auth (widgets and BG tasks read shared state).
- **Widgets still show numbers when the app is locked** — that's an iOS reality; add a Settings
  footnote, and don't pretend the lock covers widgets.
- `evaluatePolicy` can be called while `.inactive` and silently fail — only trigger auth when
  `scenePhase == .active`.
- Sheets presented over RootView (password entry, OAuth `ASWebAuthenticationSession`) must sit *under*
  the lock overlay — test that returning from Face ID doesn't dismiss an in-progress OAuth session.
- Simulator: Features → Face ID → Enrolled + Matching/Non-matching touch for testing.

## Acceptance criteria

- [ ] Toggle on → background the app → reopen after grace: Face ID prompt; success reveals the app,
      cancel keeps the cover with a retry button.
- [ ] App switcher shows the cover, not balances.
- [ ] Device without passcode: toggle refuses with an explanation.
- [ ] Gmail background scan still imports while locked (verify via a scan landing new txns).
- [ ] Build green; `NSFaceIDUsageDescription` present (App Store-style validation passes).
