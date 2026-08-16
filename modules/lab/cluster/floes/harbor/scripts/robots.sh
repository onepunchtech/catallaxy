set -eu
: "${NS:?NS env required}"
: "${HARBOR_URL:?HARBOR_URL env required}"
: "${ROBOTS_JSON:?ROBOTS_JSON env required}"

while true; do
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$HARBOR_URL/api/v2.0/ping" 2>/dev/null || echo "000")
  [ "$CODE" = "200" ] && break
  echo "Waiting for Harbor API (HTTP $CODE)..."
  sleep 5
done

create_robot() {
  local NAME="$1" SECRET="$2" PAYLOAD_FILE="$3"
  if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
    echo "Secret $SECRET already exists; skipping robot creation for $NAME"
    return 0
  fi
  RESP=$(curl -sk -u "admin:$ADMIN_PASSWORD" \
    -H 'Content-Type: application/json' \
    -X POST -d @"$PAYLOAD_FILE" \
    "$HARBOR_URL/api/v2.0/robots")
  ROBOT_NAME=$(echo "$RESP" | jq -r '.name // empty')
  ROBOT_SECRET=$(echo "$RESP" | jq -r '.secret // empty')
  if [ -z "$ROBOT_NAME" ] || [ -z "$ROBOT_SECRET" ]; then
    echo "Failed to create robot '$NAME': $RESP" >&2
    return 1
  fi
  kubectl -n "$NS" create secret docker-registry "$SECRET" \
    --docker-server="$HARBOR_EXTERNAL_HOST" \
    --docker-username="$ROBOT_NAME" \
    --docker-password="$ROBOT_SECRET"
  echo "Created robot '$ROBOT_NAME' → Secret $SECRET"
}

# One object per robot rather than one generated shell line per robot, which
# is what let this be a Nix string instead of a script.
printf '%s' "$ROBOTS_JSON" | jq -c '.[]' | while read -r robot; do
  name=$(printf '%s' "$robot" | jq -r '.name')
  secret=$(printf '%s' "$robot" | jq -r '.secretName')
  printf '%s' "$robot" | jq '.payload' >"/tmp/$name.json"
  create_robot "$name" "$secret" "/tmp/$name.json"
done
echo "All robot bootstraps complete"
