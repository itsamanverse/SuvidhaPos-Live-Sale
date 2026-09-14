# SuvidhaPos Live Sale

Flutter Android application for Suvidha POS live sales, outlet-wise analytics,
live tables and reports.

## Android release

- Flutter: 3.35.7 stable
- GitHub Actions: `.github/workflows/build-android.yml`
- API: `https://apis.suvidhapos.in/api/V1`
- Output: exactly one universal APK named `SuvidhaPos-Live-Sale.apk`

## Login reliability

- Login first uses the production request shape that was already working before
  v1.0.7: `Keys` header plus multipart `LoginID`, `Password`, and `Keys`.
- Only after a generic request-format rejection does it make one controlled
  compatibility attempt with `Keys` + `X-API-Key` headers and only
  `LoginID`/`Password` form fields. Credential/key failures are never duplicated.
- Each sign-in uses a fresh no-cache connection so changing the API key cannot
  reuse stale gateway/session state.
- Explicit server responses such as user-not-found and wrong-password are mapped
  to `User ID is wrong` and `Password is wrong`. If the backend itself returns
  only ambiguous `invalid credentials`, the app safely says that User ID or
  Password is incorrect instead of guessing which field is wrong.
- Offline, DNS, TLS, timeout, busy-server and server-unavailable failures are
  shown as human-readable messages without raw HTTP/status-code errors.
- Authentication failures are not retried; only transient transport/5xx failures
  get a short bounded retry.
- Logout keeps the saved API key. Changing the API key clears only the previous
  login credentials.

## Dashboard/data behavior

- Dashboard always loads `Dashboard/Sale` with `ids=0` and selects an outlet
  locally from original outlet-tagged rows. This avoids partial selected-outlet
  responses that expose Net Sale while other cards are blank.
- All Outlets uses a true root combined summary when present; if the API returns
  per-outlet summary rows instead, those original rows are summed rather than
  treating the first outlet as the combined total.
- Gross/Net values shown on a chart bar and its tap popup come from the same
  normalized outlet row. Gross is never fabricated from Net or another metric.
- API aliases are normalized for Tax, Discount, Covers, APC, Orders, Void,
  Modified, Complimentary, Dine-In, customer and unsettled metrics.
- Top Selling Items uses `Tablet/ListofItems/POS` with `billType=k`; a transient
  top-item request failure keeps only the previous same-filter snapshot.

## Live Tables / sync

- Live Tables use `LiveTableItem/Sale` directly with `bill_no=0` for the current
  table dataset and an exact bill only when a table detail is opened.
- The old Dashboard discovery + one-request-per-bill waterfall is removed.
- Table-name aliases such as `t_name_fk`, `TableNameFK`, `tblNameFk` and
  `tableTitle` are preserved and displayed as `Table No: <POS table name>`.
- A successful empty refresh is authoritative, so settled/closed tables disappear
  instead of stale cached rows remaining on screen. Network failures alone retain
  the last known-good snapshot.
- Dashboard and Live Tables refresh every 30 seconds, refresh immediately on
  outlet/date changes and app resume, and do not overlap periodic requests.
- All-outlet Live Table requests run in bounded batches of four to stay fast
  without producing a request burst on slow networks or large installations.

## CI

The Android workflow formats, analyzes, tests and builds the single universal
release APK. It does not patch source files or commit generated changes.
