# Live Tables API source-of-truth

Live Tables use only `POST /api/V1/LiveTableItem/Sale` for table data and table-level financial/status information.

Fields:
- `outlet_id`
- `bill_no` (`0` for the live-table dataset; the exact bill number for table details)
- configured API key (`Keys`)

The Live Tables screen uses this endpoint for:
- Running tables
- Completed tables
- All/Running/Completed counts
- Table name/number display
- Table items
- Gross Sale
- Net Sale
- Pending Amount
- Table detail popup

Dashboard/Sale is not called by `LiveTablesPage` and is never a financial fallback there.

The UI label remains `Table No:` while the POS table name is displayed, e.g. `Table No: WS1`.
