# PLAN: Subscription & recurring-bill detection with reminders

**Missing-feature rank: 3 of 10.** `Store.recurringGroups` (Store.swift:1021-1031) already groups
repeated payments by counterparty — but it's display-only. Nothing predicts the next charge, warns
before a renewal, or totals your subscription burn. This turns existing data into the "you're paying
₹649 to Netflix on Friday" feature every finance app is judged by.

## Goal

Detect cadence (monthly/weekly/quarterly/annual) per recurring group, predict the next charge date and
amount, show an "Upcoming" section (Home + Insights) with a monthly-burn total, and optionally notify
1 day before a predicted charge. Allow dismissing a group ("not a subscription").

## Files to touch

- [Nidhi/State/Store.swift](Nidhi/State/Store.swift) — extend `RecurringGroup` with
  `cadence`, `nextDate`, `expectedAmount`, `confidence`; add `upcomingCharges(within:)`. Add a
  persisted `mutedRecurringKeys: Set<String>` on Store.
- [Nidhi/State/Persistence.swift](Nidhi/State/Persistence.swift) — decode `mutedRecurringKeys`
  default `[]` (tolerant rule).
- [Nidhi/UI/HomeView.swift](Nidhi/UI/HomeView.swift) — "Upcoming" card (next 7 days).
- [Nidhi/UI/InsightsView.swift](Nidhi/UI/InsightsView.swift) — subscriptions card: monthly burn
  + list with cadence, next date, mute swipe.
- [Nidhi/Platform/Notifications.swift](Nidhi/Platform/Notifications.swift) — `recurring-<key>` reminders,
  rescheduled whenever recompute changes predictions.

## Implementation order

1. Cadence inference in `Store` (pure function — write it so the parser harness pattern could test it):
   given a group's sorted dates, median inter-charge gap → cadence bucket (26-35d = monthly, 6-8d =
   weekly, 85-100d = quarterly, 350-380d = annual); `confidence` = fraction of gaps within the bucket.
   Require ≥3 occurrences AND confidence ≥ 0.6 to predict. `expectedAmount` = median of last 3 amounts.
2. `nextDate` = last charge + cadence; if that's already past (missed/cancelled), roll forward at most
   once, and drop the group from "upcoming" if 2+ cycles passed with no charge (likely cancelled —
   surface it as "possibly cancelled" in the Insights card instead; that's a feature, not a bug).
3. Muting: swipe/context action writes the group key to `mutedRecurringKeys`; muted groups vanish from
   upcoming + notifications but stay in the Insights list (greyed) so they can be unmuted.
4. UI cards (reuse `SectionHeader`/row components), then notifications (schedule only the next 30 days;
   cancel-and-reschedule as a set to avoid orphans).

## Edge cases a weaker model would miss

- **Amount drift**: subscriptions change price (Netflix hikes). Median-of-last-3 handles it; do NOT
  require equal amounts for group membership — grouping is by counterparty key, which already exists.
- **Variable-amount recurring** (electricity bill autopay): cadence is real, amount isn't — show
  "~₹1,200" (tilde) when amount variance > 20%, and don't include it in the fixed "subscription burn"
  total; count it separately as "recurring bills".
- **SIPs and transfers**: groups classified `Transfer` or `Income` must be excluded from the burn
  total (a ₹50k SIP is not a subscription cost) but may still appear as upcoming reminders — they're
  the most valuable "don't forget to fund the account" alerts. Split the UI accordingly.
- Existing `recurringGroups` recomputes on access — the new fields make it heavier; memoise per
  `txns.count`+latest-date, or compute in `recomputeSpent` and cache.
- Notification ids must be stable per group key, or every recompute duplicates pending notifications.

## Acceptance criteria

- [ ] With real imported data, known subscriptions (e.g. Netflix/Spotify-type rows) appear with correct
      cadence and a plausible next date; a one-off large payment does not.
- [ ] Monthly burn total = sum of monthly-equivalent fixed subscriptions only (hand-check 3).
- [ ] Muting removes from Home/notifications, survives relaunch, and is reversible.
- [ ] A cancelled subscription (no charge for 2 cycles) moves to "possibly cancelled".
- [ ] Old backups restore cleanly; build green.
