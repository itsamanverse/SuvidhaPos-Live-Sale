# Deep Fix Summary — v1.0.7+9

This build focuses on login/API-key reliability, selected-outlet Dashboard
correctness, Live Table name/sync accuracy, and lower sync latency.

Key changes:
- Typed friendly login/network errors; no raw HTTP/status-code login message.
- Production login API-key header contract (`Keys` + `X-API-Key`).
- Dashboard selected-outlet filtering from authoritative `ids=0` data.
- Correct All-Outlets handling for root summary vs per-outlet summary lists.
- Expanded metric alias normalization and matching chart/popup values.
- Direct `LiveTableItem/Sale bill_no=0` live dataset instead of request waterfall.
- Table-name alias recovery and name-only table acceptance.
- Successful-empty sync clears stale tables; failure preserves last good rows.
- 30-second non-overlapping refresh with bounded all-outlet concurrency.
- Additional invariant tests for the regression-prone data paths.

## Refresh and live-table reliability
- Manual/pull refresh now preserves the currently selected outlet instead of silently switching back to All Outlets.
- Live-table outlet identity uses only explicit outlet/branch fields, so generic row `id`/`name` values cannot incorrectly filter a valid table out.
- Table names can be resolved from separate table-master rows by table ID, while numeric foreign-key values are never shown as table names.
- Dashboard LIVE refresh requests are not dropped just because a periodic Live refresh is already running.
