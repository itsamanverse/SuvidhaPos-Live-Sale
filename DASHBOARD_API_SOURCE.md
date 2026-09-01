# Dashboard API source of truth

Dashboard sales and analytics are sourced only from `POST /api/V1/Dashboard/Sale`.

Request fields:
- `from_date`
- `to_date`
- `ids=0`
- configured API key (`Keys`)

The app always requests the complete date range with `ids=0`, including when one outlet is selected. The selected outlet is filtered locally from the authoritative `outlets` rows returned by this same response. This prevents outlet-scoped POS responses from returning a partial/current-day Gross or Net value.

Dashboard Gross Sale, Net Sale, Tax, Discount, Covers, APC, Orders, customer/settlement metrics, Recent Sales, chart bars, and bar-tap details all use this endpoint.

Gross Sale is never calculated from Net Sale, Avg Revenue, Order Count, Live Tables, or item rows. If the POS response omits Gross, the UI shows zero rather than a misleading Net-as-Gross value.

Top Selling Items use the separate POS endpoint `POST /api/V1/Tablet/ListofItems/POS` with `billType=k` and are refreshed on every Dashboard sync. They are cached per outlet for transient network failures.

`LiveTableItem/Sale` remains exclusive to Live Tables.
