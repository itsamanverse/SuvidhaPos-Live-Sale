# SuvidhaPos Live Sale — Sync & Outlet Data Fixes

- Dashboard stays on a 60-second foreground timer while the Dashboard tab is active.
- Live Tables performs one immediate sync when its tab is entered and then refreshes every 60 seconds while that tab remains active. It does not poll while hidden in the `IndexedStack`.
- Reports performs one immediate **Daily** sync when its tab is entered. It does not auto-poll while the user remains on Reports. Weekly/Monthly/Yearly are fetched only when the user explicitly selects those tabs; returning to Reports starts a fresh Daily sync.
- Repeated navigation clicks are treated as explicit activation events, so a Live Tables entry always gets a fresh sync.
- Dashboard uses `ids=0` for All Outlets and `ids=<selected outlet>` for a single outlet, matching the web POS filter. The selected response is authoritative even when its summary row has no outlet ID. Dashboard discovers outlet IDs and passes them to Live Tables so All Outlets can scope per-outlet requests safely.
- Gross Sale never falls back to Net Sale, Avg Revenue, or Order Count. A missing explicit Gross field remains `0` rather than displaying Net as Gross.
- Top Selling Items are refreshed from `/Tablet/ListofItems/POS` with `billType=k` on Dashboard sync, with the last successful result retained for offline rendering.
- GitHub Actions builds one universal release APK and uploads `SuvidhaPos-Live-Sale.apk`.

## API source of truth

- Dashboard / Reports: `POST /api/V1/Dashboard/Sale`
- Live Tables: `POST /api/V1/LiveTableItem/Sale`
- Top Selling Items: `POST /api/V1/Tablet/ListofItems/POS` with `billType=k`

## Live server verification

`LIVE_SERVER_50X_TEST.md` and `.github/workflows/live-api-50x-smoke.yml` provide a manual 50x live POS smoke test. The build environment used here could not resolve the POS API host, so live-server success is not claimed without a real network run.
