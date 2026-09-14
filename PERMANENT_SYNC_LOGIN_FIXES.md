# SuvidhaPos Live Sale — Permanent Login & Sync Fixes

## Login
- Authentication uses a fresh no-cache connection per sign-in.
- Primary login exactly restores the production-compatible request used before
  v1.0.7: `Keys` header plus multipart `LoginID`, `Password`, and `Keys`.
- A second login profile (`Keys` + `X-API-Key` headers, no form key) is attempted
  only after a generic request-format rejection; explicit credential/API-key
  failures are not duplicated.
- HTTP 400/401/403/422 credential failures are not retried. Transient transport,
  timeout, 408/429/5xx failures use only a short bounded retry.
- Explicit backend wording is mapped to `User ID is wrong` or `Password is wrong`.
- If the backend itself reports only `invalid credentials`, the client cannot
  truthfully know which field failed; it shows `User ID or Password is incorrect`.
- Offline/DNS/slow/TLS/busy/server-unavailable failures are human readable and do
  not show raw status codes to the user.
- Login state is persisted only after successful authentication.
- Changing API Key clears credentials so no previous-key session can survive.

## Dashboard
- `Dashboard/Sale` is the only source of truth for Dashboard financial metrics.
- Current and previous-period Dashboard calls use `ids=0`; outlet selection is
  performed locally from rows that explicitly identify the selected outlet.
- A combined aggregate summary is never relabelled as a selected outlet.
- Same-outlet partial rows may fill missing aliases from another row for that SAME
  outlet, but values are never added twice or derived from different metrics.
- A root combined summary is used for All Outlets only when it is a real Map. A
  list of per-outlet summaries remains per-outlet data and is summed normally.
- Bar Gross/Net and bar-tap Gross/Net use the same normalized selected row.
- No Gross fallback or derived Gross calculation is used.
- Top Selling Items come from `Tablet/ListofItems/POS` (`billType=k`) with a
  same-filter stale-on-failure cache only.

## Live Tables
- Live Tables do not depend on Dashboard date filters or Dashboard/Sale discovery.
- `LiveTableItem/Sale` with `bill_no=0` is the live dataset source; exact bill
  requests are used only for table detail.
- Table names support legacy/master-field aliases and never fabricate a name from
  a numeric internal table id.
- Successful empty responses remove closed/settled tables. Only failed requests
  preserve the last known-good rows.
- All-outlet calls use bounded parallel batches of four.
- Periodic refresh is 30 seconds, non-overlapping, with immediate filter/resume
  refresh.

## Reports
- Reports use aggregate `ids=0` Dashboard data and apply the same safe local
  selected-outlet rules as Dashboard.
- No cross-outlet fallback is used.
- Failed range requests return zero for that failed range rather than blocking the
  complete report screen.

## Build
- Universal Android APK only: `flutter build apk --release`.
- No `--split-per-abi`.
- Artifact name: `SuvidhaPos-Live-Sale.apk`.
