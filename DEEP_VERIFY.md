# Deep verification checklist

The repository includes `test/deep_invariants_test.dart` with 50 iterations for the critical outlet/sale invariants:

1. All three outlet selections use the outlet row from the aggregate `Dashboard/Sale` response.
2. Gross Sale is read only from an explicit Gross field; Net/Avg Revenue/Orders are never used as a Gross fallback.
3. All Outlets keeps one row per outlet and sums those outlet rows only for outlet-wise validation; the dashboard root summary remains the combined POS total.
4. Missing Gross stays `0` instead of silently becoming Net Sale.
5. Table names such as `WS1` are displayed after the UI label `Table No:`.

The GitHub workflow runs `flutter test` and `flutter analyze --no-fatal-infos --no-fatal-warnings` before producing the single universal APK.

## API source of truth

- Dashboard: `POST /api/V1/Dashboard/Sale`
- Live Tables: `POST /api/V1/LiveTableItem/Sale`
- Top Selling Items: `POST /api/V1/Tablet/ListofItems/POS` with `billType=k`
