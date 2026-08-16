set -eu

log() { echo "[admin-reconciler] $*" >&2; }

PAT=""
for _ in $(seq 1 24); do
  PAT=$(kubectl -n "$NB_NS" get secret "$PAT_SECRET" \
    -o jsonpath="{.data.$PAT_KEY}" 2>/dev/null | base64 -d || true)
  [ -n "$PAT" ] && break
  sleep 5
done
if [ -z "$PAT" ]; then
  log "operator PAT still empty after 2 minutes; giving up (bootstrap may not have run yet)"
  exit 0
fi
AUTH=(-H "Authorization: Token $PAT" -H 'Content-Type: application/json')

if [ "$(echo "$NB_ADMIN_GROUPS_JSON" | jq 'length')" -eq 0 ]; then
  log "no adminGroupsFromJwt configured; nothing to reconcile"
  exit 0
fi

ADMIN_NAMES="$NB_ADMIN_GROUPS_JSON"
if [ -n "${JWT_GROUP_UUIDS_SECRET:-}" ]; then
  SPN_UUIDS=$(kubectl -n "$NB_NS" get secret "$JWT_GROUP_UUIDS_SECRET" \
    -o jsonpath='{.data.SPN_UUIDS_JSON}' 2>/dev/null | base64 -d || true)
  if [ -n "$SPN_UUIDS" ]; then
    ADMIN_NAMES=$(jq -cn \
      --argjson spns "$NB_ADMIN_GROUPS_JSON" \
      --argjson map "$SPN_UUIDS" \
      '$spns + [ $spns[] | . as $s | $map[$s] | select(. != null) ] | unique')
    log "matching admin groups by SPN + UUID: $ADMIN_NAMES"
  fi
fi

NB_GROUPS=$(curl -sf "$NB_URL/api/groups" "${AUTH[@]}" || echo '[]')
ADMIN_GIDS=$(echo "$ADMIN_NAMES" |
  jq -c --argjson all "$NB_GROUPS" '
      [ .[] as $spn
        | $all[] | select(.name == $spn) | .id ]
      | unique')
if [ "$(echo "$ADMIN_GIDS" | jq 'length')" -eq 0 ]; then
  log "no admin Group IDs resolved yet (SPNs: $NB_ADMIN_GROUPS_JSON)"
  exit 0
fi
log "admin group ids: $ADMIN_GIDS"

USERS=$(curl -sf "$NB_URL/api/users?service_user=false" "${AUTH[@]}" || echo '[]')
echo "$USERS" | jq -c '.[]' | while IFS= read -r u; do
  uid=$(echo "$u" | jq -r '.id')
  uname=$(echo "$u" | jq -r '.name // .email // .id')
  urole=$(echo "$u" | jq -r '.role')
  uauto=$(echo "$u" | jq -c '.auto_groups // .autoGroups // []')
  overlap=$(echo "$uauto" | jq -c --argjson admin "$ADMIN_GIDS" \
    '[ .[] | select(. as $g | $admin | index($g)) ] | length')
  if [ "$urole" = "admin" ] || [ "$urole" = "owner" ]; then
    continue
  fi
  if [ "$overlap" -eq 0 ]; then
    continue
  fi
  body=$(jq -n \
    --argjson g "$uauto" \
    --arg name "$(echo "$u" | jq -r '.name // ""')" \
    '{role:"admin", is_service_user:false, is_blocked:false, auto_groups:$g, name:$name}')
  log "promoting user '$uname' ($uid) to admin (auto_groups matches)"
  curl -sf -X PUT "$NB_URL/api/users/$uid" "${AUTH[@]}" -d "$body" >/dev/null ||
    log "PUT /api/users/$uid failed (continuing)"
done

log "done"
