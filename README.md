# SuvidhaPos Live Sale

Flutter Android application for Suvidha POS live sales, outlet-wise analytics,
live tables and reports.

## Android release

- Flutter: 3.35.7 stable
- GitHub Actions: `.github/workflows/build-android.yml`
- API: `https://apis.suvidhapos.in/api/V1`
- Output: exactly one universal APK named `SuvidhaPos-Live-Sale.apk`

## Login reliability

The login client uses a bounded compatibility matrix for the existing POS
gateway. It supports repeated Login -> Logout -> Login cycles, API-key changes,
fresh/pooled connections, and legacy API-key header/body aliases. Authentication
failures are not treated as transient network failures.

The app never deletes the saved API key during Logout. Changing the API key
clears only the old login credentials.

## Dashboard/data behavior

- All Outlets is combined by default.
- Selecting an outlet scopes dashboard, sales and item data to that outlet.
- Gross Sale uses the authoritative scoped summary before chart fallbacks.
- Top Selling Items is loaded from dashboard item rows and falls back to bill
  detail data with bounded retries.
- Live Tables rejects settled/recent-sale rows that do not represent actual
  open tables.
- Date/outlet changes invalidate dependent caches to prevent stale data crossing
  scopes.

## CI

The Android workflow formats, analyzes, tests and builds the single universal
release APK. It does not patch source files or commit generated changes.
