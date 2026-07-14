#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="$SCRIPT_DIR/grafana-service.env"
PASS_FILE="$SCRIPT_DIR/admin_password.txt"
SA_NAME="grafana-ninja"

[[ -f "$ENV_FILE" ]] || { echo "Error: $ENV_FILE not found." >&2; exit 1; }
[[ -f "$PASS_FILE" ]] || { echo "Error: $PASS_FILE not found." >&2; exit 1; }

export USER_ID="$(id -u)"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"; source "$ENV_FILE"
set +a

BASE_URL="http://127.0.0.1:${GRAFANA_PORT:?GRAFANA_PORT not set in $ENV_FILE}"
ADMIN_PASS="$(tr -d '\n' < "$PASS_FILE")"

req() { # req METHOD PATH [JSON_BODY]
    local method="$1" path="$2" body="${3:-}"
    local args=(-s -u "admin:$ADMIN_PASS" -H "Content-Type: application/json" -X "$method")
    [[ -n "$body" ]] && args+=(-d "$body")
    curl "${args[@]}" "$BASE_URL$path"
}

command -v python3 >/dev/null || { echo "Error: python3 required for JSON parsing." >&2; exit 1; }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"; }

echo "Checking Grafana at $BASE_URL ..."
curl -sf "$BASE_URL/api/health" >/dev/null || { echo "Error: Grafana is not responding at $BASE_URL." >&2; exit 1; }

SA_ID="$(req GET "/api/serviceaccounts/search?query=$SA_NAME" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); m=[s for s in d.get('serviceAccounts',[]) if s['name']=='$SA_NAME']; print(m[0]['id'] if m else '')")"

if [[ -n "$SA_ID" ]]; then
    echo "Service account '$SA_NAME' already exists (id=$SA_ID)."
else
    echo "Creating service account '$SA_NAME' (role Admin)..."
    RESP="$(req POST /api/serviceaccounts "{\"name\":\"$SA_NAME\",\"role\":\"Admin\",\"isDisabled\":false}")"
    SA_ID="$(echo "$RESP" | jget "['id']")" || { echo "Error creating service account: $RESP" >&2; exit 1; }
fi

TOKEN_NAME="$SA_NAME-$(date +%Y%m%d-%H%M%S)"
echo "Creating token '$TOKEN_NAME'..."
RESP="$(req POST "/api/serviceaccounts/$SA_ID/tokens" "{\"name\":\"$TOKEN_NAME\"}")"
TOKEN="$(echo "$RESP" | jget "['key']")" || { echo "Error creating token: $RESP" >&2; exit 1; }

if grep -q '^GRAFANA_API_KEY=' "$ENV_FILE"; then
    sed -i "s|^GRAFANA_API_KEY=.*|GRAFANA_API_KEY=$TOKEN|" "$ENV_FILE"
else
    echo "GRAFANA_API_KEY=$TOKEN" >> "$ENV_FILE"
fi

echo "GRAFANA_API_KEY updated in $ENV_FILE (do not commit the real token)."
