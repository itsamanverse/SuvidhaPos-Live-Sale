# SuvidhaPos Live Sale — Permanent Login & Sync Fixes

## Login
- Authentication uses one fresh connection per sign-in attempt.
- HTTP 400/401/403/422 authentication failures are never retried.
- Transport failures may use a bounded retry; this is separate from credential failures.
- Login keeps the server response body so a POS deployment that explicitly reports a wrong user or wrong password can show the correct friendly message instead of `Server error (400)`.
- A generic HTTP 400 cannot be mathematically split into user-vs-password when the server itself does not identify which credential failed; the app therefore uses explicit server wording when available and a safe generic credential message otherwise.
- Login state is not persisted until authentication succeeds, so a failed attempt cannot poison the next attempt.

## Dashboard
- Dashboard/Sale is the only source of truth for Dashboard metrics.
- All Outlets uses the API combined response (`ids=0`).
- A selected outlet uses an outlet-scoped Dashboard/Sale request (`ids=<outlet>`).
- For a selected outlet, a complete outlet row is preferred over a partial/net-only summary row. If the scoped response contains one unlabelled summary row, it is accepted as the scoped outlet response and given outlet context.
- Selected-outlet bill/recent-sale and item rows are scoped using explicit outlet metadata when present; if the scoped API omits outlet metadata, the rows are retained because the request itself is already outlet-scoped.
- Bar Gross Sale and the Gross Sale card use the same authoritative normalized Dashboard/Sale row.
- No Gross fallback or derived Gross calculation is used.

## Live Tables
- Live Tables do not depend on Dashboard From Date / To Date.
- Dashboard/Sale is discovery-only for current bill/table keys.
- Financial values come from LiveTableItem/Sale.
- Running and Completed tables are both retained.
- Temporary request failures preserve the last known-good snapshot.
- Outlet requests run in parallel with bounded concurrency.

## Reports
- Reports use the same selected-outlet scoped summary rules as Dashboard.
- No cross-outlet fallback is used.
- Failed range requests return zero for that range rather than blocking the entire report screen.

## Build
- Universal Android APK only: `flutter build apk --release`.
- No `--split-per-abi`.
- Artifact name: `SuvidhaPos-Live-Sale.apk`.
