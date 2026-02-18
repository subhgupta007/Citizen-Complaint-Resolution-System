#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-egov}"
DEPLOYMENT="${DEPLOYMENT:-gateway}"
ENV_FILE="${ENV_FILE:-devops/deploy-as-code/charts/environments/env.yaml}"
TOKEN="${TOKEN:-}"
BASE_URL="${BASE_URL:-}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' is required for this step." >&2
    return 1
  }
}

echo "[1/4] Checking repo env values"
if rg -n 'egov-mixed-mode-endpoints-whitelist:.*(/user/_search|$)' "$ENV_FILE" >/dev/null; then
  echo "PASS: $ENV_FILE contains /user/_search under egov-mixed-mode-endpoints-whitelist"
else
  echo "FAIL: /user/_search not found in $ENV_FILE egov-mixed-mode-endpoints-whitelist"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "WARN: kubectl not available; skipping live cluster validation/log checks."
  exit 0
fi

echo "[2/4] Comparing live gateway env var vs repo"
LIVE_VALUE="$(kubectl -n "$NAMESPACE" get deploy "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EGOV_MIXED_MODE_ENDPOINTS_WHITELIST")].value}')"
if [[ -z "$LIVE_VALUE" ]]; then
  echo "WARN: Could not read EGOV_MIXED_MODE_ENDPOINTS_WHITELIST from deployment/$DEPLOYMENT"
else
  if [[ "$LIVE_VALUE" == *"/user/_search"* ]]; then
    echo "PASS: Live deployment env has /user/_search"
  else
    echo "FAIL: Live deployment env missing /user/_search"
  fi
fi

if [[ -n "$BASE_URL" && -n "$TOKEN" ]]; then
  echo "[3/4] Sending request through gateway with Authorization: Bearer <token>"
  require_cmd curl
  require_cmd sed
  CURL_OUT="$(curl -sS -o /tmp/user_search_response.json -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    --data '{"RequestInfo":{"authToken":"'"${TOKEN}"'"},"userName":"test"}' \
    "${BASE_URL%/}/user/_search")"
  echo "Gateway response status: $CURL_OUT"
  sed -n '1,10p' /tmp/user_search_response.json || true
else
  echo "WARN: BASE_URL and/or TOKEN unset; skipping live request check."
fi

echo "[4/4] Recent gateway auth filter logs"
kubectl -n "$NAMESPACE" logs deploy/"$DEPLOYMENT" --since=30m | rg -n 'Auth|auth|Bearer|token|401|Unauthorized' || true

echo "Done."
