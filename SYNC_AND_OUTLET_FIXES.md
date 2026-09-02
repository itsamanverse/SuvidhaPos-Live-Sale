# SuvidhaPos Live Sale — Sync & Outlet Data Fixes

- Dashboard and Live Tables auto-refresh every 60 seconds.
- Dashboard discovers outlet IDs and passes them to Live Tables so All Outlets can scope per-outlet requests safely.
- Single-outlet Dashboard/Sale responses are treated as already scoped even when their summary row has no outlet ID.
- Gross Sale never falls back to Net Sale or any derived metric.
- Top Selling Items are reconciled on every dashboard sync while existing bill details remain cached.
- GitHub Actions builds one universal release APK and uploads `SuvidhaPos-Live-Sale.apk`.

- Live Tables financial/status data comes only from `/LiveTableItem/Sale` per outlet + bill; Dashboard/Sale is discovery-only. Gross Sale, Net Sale, and Pending Amount have no fallback or derived-value path. All Outlets aggregates original API fields from the outlet-scoped responses; a selected outlet uses only that outlet's response rows.
- Live table cards and popup use the POS table identifier as `Table No: WS1` rather than converting it to `Table 1`.
