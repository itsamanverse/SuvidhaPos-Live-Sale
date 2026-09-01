#!/usr/bin/env bash
set -euo pipefail

: "${SUPVIDHA_API_KEY:?Set SUPVIDHA_API_KEY}"
BASE_URL="${SUPVIDHA_BASE_URL:-https://apis.suvidhapos.in/api/V1}"
FROM_DATE="${SUPVIDHA_FROM_DATE:-2026-08-29}"
TO_DATE="${SUPVIDHA_TO_DATE:-2026-08-29}"
OUTLET_ID="${SUPVIDHA_OUTLET_ID:-1}"
LOGIN_ID="${SUPVIDHA_LOGIN_ID:-}"
LOGIN_PASSWORD="${SUPVIDHA_LOGIN_PASSWORD:-}"
SECOND_KEY="${SUPVIDHA_API_KEY_2:-}"

request() {
  local label="$1"; shift
  local tmp status
  tmp=$(mktemp)
  status=$(curl -sS --fail-with-body --max-time 30 -o "$tmp" -w '%{http_code}' "$@" || true)
  if [[ "$status" != 2* ]]; then
    echo "FAIL $label HTTP=$status"
    head -c 400 "$tmp" || true
    echo
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  echo "PASS $label HTTP=$status"
}

for i in $(seq 1 50); do
  request "Dashboard/Sale #$i" \
    --location "$BASE_URL/Dashboard/Sale" \
    --header 'accept: /' \
    --form "from_date=$FROM_DATE" \
    --form "to_date=$TO_DATE" \
    --form 'ids=0' \
    --form "Keys=$SUPVIDHA_API_KEY" >/dev/null
  echo "Dashboard $i/50"
done

for i in $(seq 1 50); do
  request "LiveTableItem/Sale #$i" \
    --location "$BASE_URL/LiveTableItem/Sale" \
    --header 'accept: /' \
    --form "outlet_id=$OUTLET_ID" \
    --form 'bill_no=0' \
    --form "Keys=$SUPVIDHA_API_KEY" >/dev/null
  echo "Live Tables $i/50"
done

for i in $(seq 1 50); do
  request "Tablet/ListofItems/POS #$i" \
    --location "$BASE_URL/Tablet/ListofItems/POS" \
    --header 'accept: /' \
    --form 'billType=k' \
    --form "Keys=$SUPVIDHA_API_KEY" >/dev/null
  echo "Top Items $i/50"
done

if [[ -n "$LOGIN_ID" && -n "$LOGIN_PASSWORD" ]]; then
  for i in $(seq 1 20); do
    request "DashboardLogin #$i" \
      --location "$BASE_URL/DashboardLogin" \
      --header 'accept: application/json, text/plain, */*' \
      --header "Keys: $SUPVIDHA_API_KEY" \
      --header "X-API-Key: $SUPVIDHA_API_KEY" \
      --form "LoginID=$LOGIN_ID" \
      --form "Password=$LOGIN_PASSWORD" >/dev/null
    echo "Login $i/20"
  done
fi

if [[ -n "$SECOND_KEY" && -n "$LOGIN_ID" && -n "$LOGIN_PASSWORD" ]]; then
  for key_name in SUPVIDHA_API_KEY SUPVIDHA_API_KEY_2; do
    key_value="${!key_name}"
    for i in $(seq 1 10); do
      request "Login key=$key_name #$i" \
        --location "$BASE_URL/DashboardLogin" \
        --header 'accept: application/json, text/plain, */*' \
        --header "Keys: $key_value" \
        --header "X-API-Key: $key_value" \
        --form "LoginID=$LOGIN_ID" \
        --form "Password=$LOGIN_PASSWORD" >/dev/null
    done
  done
fi

echo 'LIVE SERVER SMOKE TEST: PASS'
