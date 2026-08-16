set -eu
: "${HARBOR_URL:?HARBOR_URL env required}"
: "${OIDC_CONFIG_JSON:?OIDC_CONFIG_JSON env required}"

# The client secret is the one value that cannot be in OIDC_CONFIG_JSON: it
# lives in a Secret and only exists once the IdP has been provisioned.
if [ -n "${OIDC_CLIENT_SECRET_NAME:-}" ]; then
  OIDC_CLIENT_SECRET=$(kubectl -n "$OIDC_CLIENT_SECRET_NS" get secret "$OIDC_CLIENT_SECRET_NAME" \
    -o "jsonpath={.data.$OIDC_CLIENT_SECRET_KEY}" | base64 -d)
  printf '%s' "$OIDC_CONFIG_JSON" |
    jq --arg s "$OIDC_CLIENT_SECRET" '.oidc_client_secret = $s' >/tmp/payload.json
else
  printf '%s' "$OIDC_CONFIG_JSON" >/tmp/payload.json
fi

while true; do
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$HARBOR_URL/api/v2.0/ping" 2>/dev/null || echo "000")
  [ "$CODE" = "200" ] && break
  echo "Waiting for Harbor API (HTTP $CODE)..."
  sleep 5
done
echo "Harbor API reachable, applying OIDC configuration"

HTTP=$(curl -sk -w '%{http_code}' -o /tmp/resp.txt \
  -u "admin:$ADMIN_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X PUT \
  -d @/tmp/payload.json \
  "$HARBOR_URL/api/v2.0/configurations")
if [ "$HTTP" != "200" ]; then
  echo "Failed to apply OIDC config (HTTP $HTTP):"
  cat /tmp/resp.txt
  exit 1
fi
echo "OIDC configuration applied"
