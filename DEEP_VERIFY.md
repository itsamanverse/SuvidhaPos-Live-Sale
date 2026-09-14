# Deep verification checklist

`test/deep_invariants_test.dart` covers the critical public data invariants:

1. Gross Sale is read only from an explicit Gross field and is never derived
   from Net/Avg Revenue/Orders.
2. Aggregate `ids=0` data cannot relabel a combined summary as a selected outlet.
3. Partial rows for the SAME outlet can fill missing canonical aliases without
   adding/deriving financial values.
4. Secondary Dashboard aliases normalize into APC/Void/Modified/Complimentary/
   Dine-In/Customer/Unsettled cards.
5. Live table names preserve original POS values across common FK/name variants.

The repository GitHub workflow runs `flutter test` and `flutter analyze` before
producing the universal Android APK. This container does not include a Flutter SDK,
so final local verification here also includes structural Dart-source checks, API
contract/source checks, stale-cache checks, and diff review.

## API source of truth

- Dashboard: `POST /api/V1/Dashboard/Sale` with `ids=0`
- Live Tables: `POST /api/V1/LiveTableItem/Sale` (`bill_no=0` dataset)
- Top Selling Items: `POST /api/V1/Tablet/ListofItems/POS` with `billType=k`
- Login primary: `POST /api/V1/DashboardLogin` with `Keys` header + multipart `Keys`; compatibility fallback uses `Keys` + `X-API-Key` headers
