# Login Hotfix — v1.0.8+10

## Root cause

v1.0.7 changed DashboardLogin from the request shape used by the previously
working mobile client (`Keys` header + multipart `Keys`) to a header-only API-key
shape. The live server shown by the user rejected that request before credentials
could be accepted.

## Fix

1. Primary login is restored to the previous production-compatible request:
   - header: `Keys`
   - multipart: `LoginID`, `Password`, `Keys`
2. A single fallback profile is retained for alternate gateway deployments:
   - headers: `Keys`, `X-API-Key`
   - multipart: `LoginID`, `Password`
3. Fallback is not used when the backend already reports a credential or API-key
   error. It is only used for generic request-format rejection (400/415/422, or
   explicit missing-header wording on 401/403).
4. Friendly User ID / Password / network / timeout / server messages remain.
5. Dashboard, Live Tables, outlet filtering and 30-second sync fixes from v1.0.7
   are unchanged.

## Limitation

If the backend itself only says `invalid credentials`, the mobile client cannot
truthfully determine whether the User ID or password was wrong. It therefore
shows the combined credential message rather than guessing.
