# SuvidhaPos Live Sale — Sync & Outlet Data Fixes

- Dashboard and Live Tables auto-refresh every 30 seconds and periodic refreshes
  do not overlap. Outlet/date changes and app resume refresh immediately.
- Dashboard always calls `Dashboard/Sale` with `ids=0`; a single outlet is chosen
  locally only from rows that positively identify that outlet.
- Aggregate/root totals are never relabelled as a selected outlet.
- All Outlets supports both a root combined summary and a list of per-outlet
  summary rows without accidentally using only the first outlet.
- Dashboard metric aliases are normalized for all cards, including APC, Void,
  Modified, Complimentary, Dine-In, Customers Served and Unsettled values.
- Gross Sale never falls back to Net Sale or any derived metric.
- Chart bars and bar-tap popup share the same Gross/Net source row.
- Top Selling Items use `/Tablet/ListofItems/POS` with `billType=k`; transient
  failure preserves only the existing same-date/same-outlet snapshot.
- Live Tables call `/LiveTableItem/Sale` directly with `bill_no=0`; Dashboard is
  not used as a discovery or financial source. Exact-bill requests are detail only.
- Successful empty Live Table refreshes clear settled/closed tables. Failed outlet
  requests preserve only that outlet's last good snapshot.
- All-outlet Live Table calls run in bounded batches of four.
- POS table names support additional FK/name aliases and display as
  `Table No: WS1` (or the exact POS name) without converting numeric IDs.
- GitHub Actions builds one universal release APK and uploads
  `SuvidhaPos-Live-Sale.apk`.
