# SuvidhaPos Live Sale — Sync & Outlet Data Fixes

- Dashboard and Live Tables auto-refresh every 60 seconds.
- Dashboard discovers outlet IDs and passes them to Live Tables so All Outlets can scope per-outlet requests safely.
- Single-outlet Dashboard/Sale responses are treated as already scoped even when their summary row has no outlet ID.
- Missing single-outlet metrics are backfilled only from the matching aggregate outlet row when the scoped value is zero.
- Gross Sale never falls back to Net Sale. When the POS omits an explicit gross field, Gross Sale is derived from Avg Revenue (Per Bill) × Order Count, matching the web POS metric.
- Gross/Tax/Discount/other summary fields can also be backfilled from uniquely identified bill rows when those fields are absent.
- Top Selling Items are reconciled on every dashboard sync while existing bill details remain cached.
- GitHub Actions builds one universal release APK and uploads `SuvidhaPos-Live-Sale.apk`.

- Live Tables financial/status data now comes from `/LiveTableItem/Sale` per outlet + bill; Dashboard/Sale is discovery-only.
- Live table cards and popup use the POS table identifier as `Table No: WS1` rather than converting it to `Table 1`.
