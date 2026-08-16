set -eu

log() { echo "[bootstrap] $*"; }

CACERT_FLAG=""
if [ -f /etc/ssl/certs/lab-ca.crt ]; then
  CACERT_FLAG="--cacert /etc/ssl/certs/lab-ca.crt"
fi

configure_account() {
  local pat="$1"
  log "resolving account id for settings patch"
  ACCOUNT_ID=$(curl -sk $CACERT_FLAG \
    -H "Authorization: Token $pat" \
    -H "Accept: application/json" \
    "$NB_URL/api/accounts" | jq -r '.[0].id // empty')
  if [ -z "$ACCOUNT_ID" ]; then
    log "no account visible via /api/accounts; skipping settings patch" >&2
    return
  fi
  CUR=$(curl -sk $CACERT_FLAG \
    -H "Authorization: Token $pat" \
    -H "Accept: application/json" \
    "$NB_URL/api/accounts" | jq -r '.[0].settings')
  NEW=$(echo "$CUR" | jq \
    --argjson lazy "$NB_LAZY_CONNECTIONS" \
    --arg claim "$NB_JWT_GROUPS_CLAIM" \
    --argjson allow "$NB_JWT_ALLOW_GROUPS" '
    .extra.user_approval_required = false
    | .extra.peer_approval_enabled = false
    | .lazy_connection_enabled = $lazy
    | .jwt_groups_enabled = true
    | .jwt_groups_claim_name = $claim
    | if ($allow | length) > 0 then .jwt_allow_groups = $allow else . end
  ')
  if [ "$CUR" = "$NEW" ]; then
    log "account $ACCOUNT_ID settings already ok"
  else
    log "patching account $ACCOUNT_ID (user_approval_required=false, peer_approval_enabled=false, lazy_connection_enabled=$NB_LAZY_CONNECTIONS, jwt_groups_enabled=true, jwt_groups_claim_name=$NB_JWT_GROUPS_CLAIM)"
    curl -sk $CACERT_FLAG -X PUT \
      -H "Authorization: Token $pat" \
      -H "Content-Type: application/json" \
      "$NB_URL/api/accounts/$ACCOUNT_ID" \
      -d "$(jq -n --argjson s "$NEW" '{settings: $s}')" >/dev/null
  fi
}

discover_jwt_group_uuids() {
  local id_token="$1"
  [ -n "${NB_JWT_SPNS_JSON:-}" ] || return 0
  [ "$(echo "$NB_JWT_SPNS_JSON" | jq 'length')" -gt 0 ] || return 0
  if [ -z "$id_token" ] || [ "$id_token" = "null" ]; then
    log "no id_token available; skipping JWT group UUID discovery" >&2
    return 0
  fi
  local payload
  payload=$(echo "$id_token" | cut -d. -f2 | tr '_-' '/+')
  case $((${#payload} % 4)) in
  2) payload="${payload}==" ;;
  3) payload="${payload}=" ;;
  esac
  local groups_claim
  groups_claim=$(echo "$payload" | base64 -d 2>/dev/null | jq -c '.groups // []')
  local spn_uuids_json
  spn_uuids_json=$(jq -cn \
    --argjson g "$groups_claim" \
    --argjson spns "$NB_JWT_SPNS_JSON" \
    '
      [ $spns[] as $spn
        | ($g | to_entries[] | select(.value == $spn) | .key) as $i
        | select(($i // 0) > 0)
        | $g[$i - 1] as $u
        | select($u | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
        | {($spn): $u}
      ]
      | add // {}
    ')
  local resolved expected
  resolved=$(echo "$spn_uuids_json" | jq 'length')
  expected=$(echo "$NB_JWT_SPNS_JSON" | jq 'length')
  log "resolved $resolved/$expected JWT group UUIDs: $spn_uuids_json"
  if [ "$resolved" -lt "$expected" ]; then
    local missing
    missing=$(jq -cn \
      --argjson a "$NB_JWT_SPNS_JSON" \
      --argjson h "$spn_uuids_json" \
      '$a | map(select(. as $s | ($h | has($s) | not)))')
    log "WARNING: missing JWT group UUIDs for SPNs: $missing" >&2
    log "  add netbird-bot to each SPN's kanidm group and re-run bootstrap" >&2
    log "  bot id_token groups claim: $groups_claim" >&2
  fi
  kubectl -n "$NB_NS" create secret generic "$JWT_GROUP_UUIDS_SECRET" \
    --from-literal="SPN_UUIDS_JSON=$spn_uuids_json" \
    --dry-run=client -o yaml |
    kubectl apply -f -
  log "wrote $NB_NS/$JWT_GROUP_UUIDS_SECRET (key SPN_UUIDS_JSON)"
}

do_token_exchange() {
  local client_id="$OAUTH2_CLIENT_NAME"
  if [ -z "$client_id" ]; then
    log "OAUTH2_CLIENT_NAME env not set" >&2
    exit 1
  fi
  local bot_token
  bot_token=$(kubectl -n "$BOT_TOKEN_NS" get secret "$BOT_TOKEN_SECRET" \
    -o jsonpath='{.data.'"$BOT_TOKEN_KEY"'}' 2>/dev/null | base64 -d || true)
  if [ -z "$bot_token" ]; then
    log "bot Secret $BOT_TOKEN_NS/$BOT_TOKEN_SECRET missing key $BOT_TOKEN_KEY" >&2
    log "verify the KanidmServiceAccount has reconciled and minted its API token." >&2
    exit 1
  fi
  local token_endpoint="${TOKEN_ENDPOINT:-}"
  if [ -n "$token_endpoint" ]; then
    log "using provider-supplied token endpoint $token_endpoint" >&2
  else
    if [ -z "$OIDC_DISCOVERY" ]; then
      log "neither TOKEN_ENDPOINT nor OIDC_DISCOVERY is set; check idp.machine wiring" >&2
      exit 1
    fi
    log "fetching OIDC discovery from $OIDC_DISCOVERY" >&2
    local disc
    disc=$(curl -sf $CACERT_FLAG "$OIDC_DISCOVERY" 2>&1) || {
      log "OIDC discovery fetch failed: $disc" >&2
      exit 1
    }
    token_endpoint=$(echo "$disc" | jq -r '.token_endpoint // empty')
    if [ -z "$token_endpoint" ]; then
      log "no token_endpoint in discovery response" >&2
      exit 1
    fi
  fi
  log "requesting token-exchange access token from $token_endpoint" >&2
  local resp
  resp=$(curl -sf $CACERT_FLAG \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    --data-urlencode "subject_token=$bot_token" \
    --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    --data-urlencode "client_id=$client_id" \
    --data-urlencode "scope=openid email profile groups" \
    "$token_endpoint" 2>&1) || {
    log "kanidm token endpoint refused token-exchange: $resp" >&2
    exit 1
  }
  printf '%s' "$resp"
}

EXISTING=$(kubectl -n "$NB_NS" get secret "$OUT_SECRET" \
  -o jsonpath='{.data.'"$OUT_KEY"'}' 2>/dev/null | base64 -d || true)
UUIDS_PRESENT=$(kubectl -n "$NB_NS" get secret "$JWT_GROUP_UUIDS_SECRET" \
  -o jsonpath='{.data.SPN_UUIDS_JSON}' 2>/dev/null | base64 -d 2>/dev/null || true)
UUIDS_NEEDED=$([ -n "${NB_JWT_SPNS_JSON:-}" ] &&
  [ "$(echo "$NB_JWT_SPNS_JSON" | jq 'length')" -gt 0 ] &&
  echo yes || echo no)
UUIDS_STALE=no
if [ "$UUIDS_NEEDED" = "yes" ] && [ -n "$UUIDS_PRESENT" ]; then
  missing=$(jq -cn --argjson a "$NB_JWT_SPNS_JSON" --argjson h "$UUIDS_PRESENT" \
    '$a | map(select(. as $s | ($h | has($s) | not)))')
  if [ "$(echo "$missing" | jq 'length')" -gt 0 ]; then
    UUIDS_STALE=yes
    log "existing JWT group UUIDs Secret is stale; missing SPNs: $missing"
  fi
fi
if [ -n "$EXISTING" ] && [ "$EXISTING" != "" ]; then
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
    "$NB_URL/api/users/current" \
    -H "Authorization: Token $EXISTING" 2>/dev/null || echo 000)
  if [ "$CODE" = "200" ]; then
    if [ "$UUIDS_NEEDED" = "yes" ] && { [ -z "$UUIDS_PRESENT" ] || [ "$UUIDS_STALE" = "yes" ]; }; then
      log "existing PAT valid; running token-exchange to (re)populate JWT group UUIDs Secret"
      RESP=$(do_token_exchange)
      discover_jwt_group_uuids "$(echo "$RESP" | jq -r '.id_token // empty')"
    else
      log "existing PAT + JWT group UUIDs already present; skipping mint"
    fi
    configure_account "$EXISTING"
    exit 0
  fi
  log "existing PAT rejected (HTTP $CODE); re-minting"
fi

log "waiting for Netbird management API"
for _ in $(seq 1 60); do
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$NB_URL/api/users" 2>/dev/null || echo 000)
  if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
    log "API up (HTTP $CODE)"
    break
  fi
  sleep 5
done

RESP=$(do_token_exchange)
TOKEN=$(echo "$RESP" | jq -r '.access_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  log "no access_token in kanidm response: $RESP" >&2
  exit 1
fi
log "got OIDC access token"

log "calling Netbird /api/users (auto-promote)"
USERS=$(curl -sf "$NB_URL/api/users" \
  -H "Authorization: Bearer $TOKEN" 2>&1) || {
  log "Netbird rejected the OIDC token: $USERS" >&2
  log "Netbird API audience or issuer may not match kanidm's claims." >&2
  exit 1
}

SELF_ID=$(echo "$USERS" |
  jq -r '.[] | select(.is_current==true) | .id' |
  head -1)
if [ -z "$SELF_ID" ] || [ "$SELF_ID" = "null" ]; then
  SELF_ID=$(echo "$USERS" | jq -r '.[] | select(.role=="admin") | .id' | head -1)
fi
if [ -z "$SELF_ID" ] || [ "$SELF_ID" = "null" ]; then
  log "could not determine self user id from response: $USERS" >&2
  exit 1
fi
log "self user id: $SELF_ID"

PAYLOAD=$(jq -n --arg n "catallaxy-operator" \
  '{name: $n, expires_in: 365}')
PAT_RESP=$(curl -sf -X POST "$NB_URL/api/users/$SELF_ID/tokens" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" 2>&1) || {
  log "PAT mint failed: $PAT_RESP" >&2
  exit 1
}
PAT=$(echo "$PAT_RESP" | jq -r '.plain_token // .secret // empty')
if [ -z "$PAT" ]; then
  log "no plain token in mint response: $PAT_RESP" >&2
  exit 1
fi

kubectl -n "$NB_NS" create secret generic "$OUT_SECRET" \
  --from-literal="$OUT_KEY=$PAT" \
  --dry-run=client -o yaml |
  kubectl apply -f -
log "wrote $NB_NS/$OUT_SECRET with key $OUT_KEY"

discover_jwt_group_uuids "$(echo "$RESP" | jq -r '.id_token // empty')"
configure_account "$PAT"
