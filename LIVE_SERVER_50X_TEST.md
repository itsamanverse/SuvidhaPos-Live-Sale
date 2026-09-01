# Live POS 50x smoke test

The local execution environment used for this build could not resolve `apis.suvidhapos.in`, so a genuine 50x live-server run could not be honestly marked as passed here.

A manual GitHub Actions workflow is included for the real POS server test. It never prints the API key or password.

Set these repository Actions secrets before running it:

- `SUPVIDHA_API_KEY` — required
- `SUPVIDHA_LOGIN_ID` — optional; enables repeated login testing
- `SUPVIDHA_LOGIN_PASSWORD` — optional; enables repeated login testing
- `SUPVIDHA_API_KEY_2` — optional second valid key; enables key-switch login testing

Optional workflow variables:

- `SUPVIDHA_OUTLET_ID` (default `1`)
- `SUPVIDHA_FROM_DATE` (default `2026-08-29`)
- `SUPVIDHA_TO_DATE` (default `2026-08-29`)

The workflow tests 50 Dashboard/Sale calls, 50 LiveTableItem/Sale calls, 50 Top Selling Item calls, and 20 login calls when login secrets are configured. If a second API key is configured, it performs 10 login calls with each key.
