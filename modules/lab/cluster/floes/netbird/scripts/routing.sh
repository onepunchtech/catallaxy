set -eu

log() { echo "[routing] $*" >&2; }

nb_write() {
  local method="$1" path="$2" body="${3-}"
  local out code
  out=$(mktemp)
  if [ -n "$body" ]; then
    code=$(curl -s -o "$out" -w '%{http_code}' -X "$method" "$NB_URL/api/$path" \
      "${AUTH[@]}" -d "$body")
  else
    code=$(curl -s -o "$out" -w '%{http_code}' -X "$method" "$NB_URL/api/$path" \
      "${AUTH[@]}")
  fi
  case "$code" in
  2*)
    cat "$out"
    rm -f "$out"
    ;;
  *)
    log "$method /api/$path failed with HTTP $code:" >&2
    sed 's/^/    /' "$out" >&2
    echo >&2
    rm -f "$out"
    return 1
    ;;
  esac
}

nb_try() {
  nb_write "$@" >/dev/null || log "  (ignored; this call is best-effort)" >&2
}

log "waiting for operator PAT in $PAT_SECRET/$PAT_KEY"
PAT=""
for _ in $(seq 1 120); do
  PAT=$(kubectl -n "$NB_NS" get secret "$PAT_SECRET" \
    -o jsonpath="{.data.$PAT_KEY}" 2>/dev/null | base64 -d || true)
  if [ -n "$PAT" ]; then break; fi
  sleep 5
done
if [ -z "$PAT" ]; then
  log "operator PAT still empty after 10 minutes; bootstrap Job likely failed" >&2
  exit 1
fi
AUTH=(-H "Authorization: Token $PAT" -H 'Content-Type: application/json')

log "waiting for management API"
for _ in $(seq 1 60); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "$NB_URL/api/groups" "${AUTH[@]}" 2>/dev/null || echo 000)
  if [ "$CODE" = "200" ]; then
    log "API up"
    break
  fi
  sleep 5
done

SPN_UUIDS_MAP="{}"
if [ -n "${JWT_GROUP_UUIDS_SECRET:-}" ]; then
  raw=$(kubectl -n "$NB_NS" get secret "$JWT_GROUP_UUIDS_SECRET" \
    -o jsonpath='{.data.SPN_UUIDS_JSON}' 2>/dev/null | base64 -d || true)
  if [ -n "$raw" ]; then
    SPN_UUIDS_MAP="$raw"
    log "loaded SPN→UUID map: $SPN_UUIDS_MAP"
  else
    log "WARNING: $JWT_GROUP_UUIDS_SECRET has no SPN_UUIDS_JSON; routing gates may not match peers"
  fi
fi

group_id() {
  local name="$1"
  local all
  all=$(curl -sf "$NB_URL/api/groups" "${AUTH[@]}")
  local id
  id=$(echo "$all" | jq -r --arg n "$name" \
    '.[] | select(.name==$n and .issued=="api") | .id' | head -1)
  if [ -n "$id" ]; then
    echo "$id"
    return
  fi
  echo "$all" | jq -r --arg n "$name" \
    '.[] | select(.name==$n) | .id' | head -1
}

group_ids_for_spn() {
  local spn="$1"
  local api_id
  api_id=$(group_id "$spn")
  if [ -n "$api_id" ]; then
    echo "$api_id"
  fi
  local uuid
  uuid=$(echo "$SPN_UUIDS_MAP" | jq -r --arg s "$spn" '.[$s] // empty')
  if [ -n "$uuid" ]; then
    local jwt_id
    jwt_id=$(curl -sf "$NB_URL/api/groups" "${AUTH[@]}" |
      jq -r --arg n "$uuid" '.[] | select(.name==$n and .issued=="jwt") | .id' | head -1)
    if [ -n "$jwt_id" ]; then
      echo "$jwt_id"
    fi
  fi
  return 0
}

ROUTER_GID=""
for _ in $(seq 1 30); do
  ROUTER_GID=$(group_id "$ROUTER_GROUP")
  if [ -n "$ROUTER_GID" ]; then break; fi
  log "waiting for group '$ROUTER_GROUP' to be created by Group CR reconcile..."
  sleep 5
done
if [ -z "$ROUTER_GID" ]; then
  log "group '$ROUTER_GROUP' not found in netbird; aborting" >&2
  exit 1
fi

SOURCE_GIDS_FILE=$(mktemp)
trap 'rm -f "$SOURCE_GIDS_FILE"' EXIT
for src_name in $SOURCE_GROUPS; do
  gid=""
  for _ in $(seq 1 30); do
    gid=$(group_id "$src_name")
    if [ -n "$gid" ]; then break; fi
    sleep 5
  done
  if [ -z "$gid" ]; then
    log "group '$src_name' not found in netbird after 150s; skipping" >&2
    continue
  fi
  group_ids_for_spn "$src_name" >>"$SOURCE_GIDS_FILE"
done
sort -u "$SOURCE_GIDS_FILE" -o "$SOURCE_GIDS_FILE"
if [ ! -s "$SOURCE_GIDS_FILE" ]; then
  log "no source groups resolved; aborting (checked: $SOURCE_GROUPS)" >&2
  exit 1
fi
SOURCE_GIDS_JSON=$(jq -R . <"$SOURCE_GIDS_FILE" | jq -s .)
log "routers=$ROUTER_GID sources=$(tr '\n' ',' <"$SOURCE_GIDS_FILE" | sed 's/,$//')"

NETWORK_NAME="$NB_NETWORK_NAME"
NETWORK_ID=$(curl -sf "$NB_URL/api/networks" "${AUTH[@]}" |
  jq -r --arg n "$NETWORK_NAME" '.[] | select(.name==$n) | .id' | head -1)
if [ -z "$NETWORK_ID" ]; then
  log "creating Network '$NETWORK_NAME'"
  NETWORK_ID=$(nb_write POST networks \
    "$(jq -n --arg n "$NETWORK_NAME" \
      '{name:$n, description:"Managed by catallaxy"}')" | jq -r '.id')
fi
log "network=$NETWORK_ID"

ROUTER_BODY=$(jq -n --arg pgid "$ROUTER_GID" \
  '{enabled:true, masquerade:true, metric:9999, peer_groups:[$pgid]}')
ROUTER_ID=$(curl -sf "$NB_URL/api/networks/$NETWORK_ID/routers" "${AUTH[@]}" |
  jq -r '(. // []) | .[0].id // empty')
if [ -z "$ROUTER_ID" ]; then
  log "creating NetworkRouter on network=$NETWORK_ID"
  nb_write POST "networks/$NETWORK_ID/routers" "$ROUTER_BODY" >/dev/null
else
  log "updating NetworkRouter $ROUTER_ID"
  nb_write PUT "networks/$NETWORK_ID/routers/$ROUTER_ID" "$ROUTER_BODY" >/dev/null
fi

RULE_LINES_FILE=$(mktemp)
trap 'rm -f "$RULE_LINES_FILE"' EXIT

upsert_resource() {
  local rname="$1" raddr="$2" enabled="$3" dest_group_name="$4"
  local dest_gid
  dest_gid=$(group_id "$dest_group_name")
  if [ -z "$dest_gid" ]; then
    log "creating access Group '$dest_group_name' for resource '$rname'"
    dest_gid=$(nb_write POST groups \
      "$(jq -n --arg n "$dest_group_name" '{name:$n}')" | jq -r '.id')
  fi
  local existing_id
  existing_id=$(curl -sf "$NB_URL/api/networks/$NETWORK_ID/resources" "${AUTH[@]}" |
    jq -r --arg n "$rname" '(. // []) | .[] | select(.name==$n) | .id' | head -1)
  local body
  body=$(jq -n \
    --arg n "$rname" \
    --arg a "$raddr" \
    --argjson e "$enabled" \
    --arg gid "$dest_gid" \
    '{
      name: $n,
      address: $a,
      enabled: $e,
      groups: [$gid],
      description: "Managed by catallaxy"
    }')
  if [ -z "$existing_id" ]; then
    existing_id=$(nb_write POST "networks/$NETWORK_ID/resources" "$body" | jq -r '.id')
    log "created NetworkResource '$rname' ($raddr) -> $existing_id"
  else
    nb_write PUT "networks/$NETWORK_ID/resources/$existing_id" "$body" >/dev/null
    log "updated NetworkResource '$rname' ($existing_id)"
  fi
  echo "$existing_id"
}

resolve_source_gids_json() {
  local names="$1"
  local file
  file=$(mktemp)
  local n ids
  for n in $names; do
    ids=$(group_ids_for_spn "$n")
    if [ -n "$ids" ]; then
      echo "$ids" >>"$file"
    else
      log "policy source '$n' not found in netbird; skipping (Policy rule will have fewer sources)" >&2
    fi
  done
  sort -u "$file" -o "$file"
  local out
  out=$(jq -R . <"$file" | jq -s .)
  rm -f "$file"
  echo "$out"
}

echo "$NB_RESOURCES_JSON" | jq -c '.[]' | while IFS= read -r resource; do
  rname=$(echo "$resource" | jq -r '.name')
  raddr=$(echo "$resource" | jq -r '.address')
  enabled=$(echo "$resource" | jq '.enabled')
  src_names=$(echo "$resource" | jq -r '.sourceGroups | join(" ")')
  dest_group=$(echo "$resource" | jq -r '.sourceGroups[0] // empty')
  if [ -z "$dest_group" ]; then
    log "resource '$rname' has empty sourceGroups; skipping (no policy rule will grant access)"
    continue
  fi
  resource_id=$(upsert_resource "$rname" "$raddr" "$enabled" "$dest_group")
  src_gids_json=$(resolve_source_gids_json "$src_names")
  jq -nc --arg name "$rname" --arg id "$resource_id" --argjson src "$src_gids_json" \
    '{name: $name, id: $id, sources: $src}' >>"$RULE_LINES_FILE"
done

if [ ! -s "$RULE_LINES_FILE" ]; then
  log "no resources configured; skipping Policy + Nameserver"
  exit 0
fi

LIVE_RESOURCES=$(curl -sf "$NB_URL/api/networks/$NETWORK_ID/resources" "${AUTH[@]}" || echo '[]')
MISSING=$(echo "$NB_RESOURCES_JSON" | jq -r --argjson live "$LIVE_RESOURCES" \
  '.[] | . as $r | select([$live[].name] | index($r.name) | not) | "\($r.name) (\($r.address))"')
if [ -n "$MISSING" ]; then
  log "network '$NETWORK_NAME' is missing resources it was asked to provision:" >&2
  echo "$MISSING" | sed 's/^/    /' >&2
  log "nothing routes to those addresses, so their names will not resolve" >&2
  exit 1
fi

ALL_POLICIES=$(curl -sf "$NB_URL/api/policies" "${AUTH[@]}" || echo '[]')

MANAGED_POLICIES_FILE=$(mktemp)
trap 'rm -f "$RULE_LINES_FILE" "$MANAGED_POLICIES_FILE"' EXIT

while IFS= read -r rule_line; do
  rid=$(echo "$rule_line" | jq -r '.id')
  rname=$(echo "$rule_line" | jq -r '.name')
  rsrc=$(echo "$rule_line" | jq -c '.sources')
  policy_name="$rname-access"
  echo "$policy_name" >>"$MANAGED_POLICIES_FILE"
  policy_body=$(jq -n \
    --arg n "$policy_name" \
    --arg desc "Managed by catallaxy (resource: $rname)" \
    --arg rid "$rid" \
    --argjson src "$rsrc" \
    '{
      name: $n,
      description: $desc,
      enabled: true,
      rules: [{
        name: $n,
        description: $desc,
        enabled: true,
        action: "accept",
        bidirectional: true,
        protocol: "all",
        sources: $src,
        destinationResource: {id: $rid, type: "subnet"}
      }]
    }')
  existing_id=$(echo "$ALL_POLICIES" | jq -r --arg n "$policy_name" \
    '(. // []) | .[] | select(.name==$n) | .id' | head -1)
  if [ -z "$existing_id" ]; then
    log "creating Policy '$policy_name'"
    nb_write POST policies "$policy_body" >/dev/null
  else
    log "updating Policy '$policy_name' ($existing_id)"
    nb_write PUT "policies/$existing_id" "$policy_body" >/dev/null
  fi
done <"$RULE_LINES_FILE"

echo "$ALL_POLICIES" | jq -r \
  --arg prefix "$NB_NETWORK_NAME-" \
  '(. // []) | .[] | select(.name | startswith($prefix)) | "\(.id) \(.name)"' |
  while IFS=' ' read -r pid pname; do
    if ! grep -qx "$pname" "$MANAGED_POLICIES_FILE"; then
      log "deleting stale policy '$pname' ($pid)"
      nb_try DELETE "policies/$pid"
    fi
  done

LEGACY_POLICY_NAME="$NB_NETWORK_NAME-mesh-access"
LEGACY_ID=$(echo "$ALL_POLICIES" | jq -r --arg n "$LEGACY_POLICY_NAME" \
  '(. // []) | .[] | select(.name==$n) | .id' | head -1)
if [ -n "$LEGACY_ID" ]; then
  log "deleting legacy composite policy '$LEGACY_POLICY_NAME' ($LEGACY_ID)"
  nb_try DELETE "policies/$LEGACY_ID"
fi

DEFAULT_ID=$(echo "$ALL_POLICIES" | jq -r \
  '(. // []) | .[] | select(.name=="Default") | .id' | head -1)
if [ -n "$DEFAULT_ID" ]; then
  log "deleting netbird auto-created 'Default' All-to-All policy ($DEFAULT_ID)"
  nb_try DELETE "policies/$DEFAULT_ID"
fi

if [ -n "$DNS_DOMAINS" ] && [ -n "$RESOLVER_IP" ]; then
  NSG_NAME="catallaxy-coredns"
  NSG_ID=$(curl -sf "$NB_URL/api/dns/nameservers" "${AUTH[@]}" |
    jq -r --arg n "$NSG_NAME" '(. // []) | .[] | select(.name==$n) | .id' | head -1)
  DNS_DOMAINS_JSON=$(echo "$DNS_DOMAINS" | tr ' ' '\n' | jq -R . | jq -s .)
  NSG_BODY=$(jq -n \
    --arg n "$NSG_NAME" \
    --arg ip "$RESOLVER_IP" \
    --argjson gids "$SOURCE_GIDS_JSON" \
    --argjson doms "$DNS_DOMAINS_JSON" \
    '{
      name: $n,
      description: "Managed by catallaxy",
      enabled: true,
      nameservers: [{ip:$ip, ns_type:"udp", port:53}],
      groups: $gids,
      primary: false,
      domains: $doms,
      search_domains_enabled: false
    }')
  if [ -z "$NSG_ID" ]; then
    log "creating NameserverGroup '$NSG_NAME'"
    nb_write POST dns/nameservers "$NSG_BODY" >/dev/null
  else
    log "updating NameserverGroup $NSG_ID"
    nb_write PUT "dns/nameservers/$NSG_ID" "$NSG_BODY" >/dev/null
  fi
fi

log "done"
