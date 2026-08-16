set -eu
: "${NS:?NS env required}"
: "${HARBOR_URL:?HARBOR_URL env required}"
: "${PROJECTS_JSON:?PROJECTS_JSON env required}"

while true; do
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$HARBOR_URL/api/v2.0/ping" 2>/dev/null || echo "000")
  [ "$CODE" = "200" ] && break
  echo "Waiting for Harbor API (HTTP $CODE)..."
  sleep 5
done

api() {
  local M="$1" P="$2" B="${3:-}"
  if [ -n "$B" ]; then
    curl -sk -u "admin:$ADMIN_PASSWORD" \
      -H 'Content-Type: application/json' \
      -X "$M" -d @"$B" "$HARBOR_URL$P"
  else
    curl -sk -u "admin:$ADMIN_PASSWORD" \
      -H 'Content-Type: application/json' \
      -X "$M" "$HARBOR_URL$P"
  fi
}

api_code() {
  local M="$1" P="$2" B="${3:-}"
  if [ -n "$B" ]; then
    curl -sk -u "admin:$ADMIN_PASSWORD" \
      -H 'Content-Type: application/json' \
      -o /dev/null -w '%{http_code}' \
      -X "$M" -d @"$B" "$HARBOR_URL$P"
  else
    curl -sk -u "admin:$ADMIN_PASSWORD" \
      -o /dev/null -w '%{http_code}' \
      -X "$M" "$HARBOR_URL$P"
  fi
}

ensure_registry() {
  local NAME="$1" PAYLOAD="$2"
  local ID
  ID=$(api GET "/api/v2.0/registries?q=name=$NAME" | jq -r '.[0].id // empty')
  if [ -z "$ID" ]; then
    api POST "/api/v2.0/registries" "$PAYLOAD" >/dev/null
    ID=$(api GET "/api/v2.0/registries?q=name=$NAME" | jq -r '.[0].id // empty')
    echo "Created registry endpoint '$NAME' (id=$ID)" >&2
  fi
  printf "%s" "$ID"
}

ensure_project() {
  local NAME="$1" PAYLOAD="$2"
  local PID
  PID=$(api GET "/api/v2.0/projects?name=$NAME" |
    jq -r --arg n "$NAME" '.[] | select(.name==$n) | .project_id' | head -1)
  if [ -z "$PID" ]; then
    api POST "/api/v2.0/projects" "$PAYLOAD" >/dev/null
    PID=$(api GET "/api/v2.0/projects?name=$NAME" |
      jq -r --arg n "$NAME" '.[] | select(.name==$n) | .project_id' | head -1)
    echo "Created project '$NAME' (id=$PID)" >&2
  else
    api PUT "/api/v2.0/projects/$PID" "$PAYLOAD" >/dev/null
    echo "Updated project '$NAME' (id=$PID)" >&2
  fi
  printf "%s" "$PID"
}

set_storage_quota() {
  local PID="$1" LIMIT="$2"
  local QID
  QID=$(api GET "/api/v2.0/quotas?reference=project&reference_id=$PID" |
    jq -r '.[0].id // empty')
  if [ -z "$QID" ]; then
    echo "No quota object for project $PID; skipping" >&2
    return 0
  fi
  printf '{"hard":{"storage":%s}}' "$LIMIT" >/tmp/quota.json
  api PUT "/api/v2.0/quotas/$QID" /tmp/quota.json >/dev/null
  echo "Set quota for project $PID to $LIMIT bytes" >&2
}

ensure_member() {
  local PNAME="$1" ENTITY="$2" ETYPE="$3" ROLE_ID="$4"
  local EXIST MID CUR_ROLE
  EXIST=$(api GET "/api/v2.0/projects/$PNAME/members?entityname=$ENTITY" |
    jq -r --arg n "$ENTITY" '.[]? | select(.entity_name==$n) | "\(.id):\(.role_id)"' | head -1)
  if [ -z "$EXIST" ]; then
    if [ "$ETYPE" = "2" ]; then
      printf '{"role_id":%s,"member_group":{"group_name":"%s","group_type":2}}' \
        "$ROLE_ID" "$ENTITY" >/tmp/member.json
    else
      printf '{"role_id":%s,"member_user":{"username":"%s"}}' \
        "$ROLE_ID" "$ENTITY" >/tmp/member.json
    fi
    api POST "/api/v2.0/projects/$PNAME/members" /tmp/member.json >/dev/null
    echo "Added member '$ENTITY' to project '$PNAME' (role=$ROLE_ID)" >&2
  else
    MID="${EXIST%%:*}"
    CUR_ROLE="${EXIST##*:}"
    if [ "$CUR_ROLE" != "$ROLE_ID" ]; then
      printf '{"role_id":%s}' "$ROLE_ID" >/tmp/member.json
      api PUT "/api/v2.0/projects/$PNAME/members/$MID" /tmp/member.json >/dev/null
      echo "Updated member '$ENTITY' on '$PNAME' (role=$ROLE_ID)" >&2
    fi
  fi
}

set_retention() {
  local PID="$1" PAYLOAD="$2"
  local RID
  RID=$(api GET "/api/v2.0/retentions?project=$PID" 2>/dev/null |
    jq -r '.id // empty' 2>/dev/null || true)
  if [ -z "$RID" ]; then
    api POST "/api/v2.0/retentions" "$PAYLOAD" >/dev/null
    echo "Created retention policy for project $PID" >&2
  else
    api PUT "/api/v2.0/retentions/$RID" "$PAYLOAD" >/dev/null
    echo "Updated retention policy $RID for project $PID" >&2
  fi
}

apply_immutable_rule() {
  local PNAME="$1" RULE_FILE="$2"
  local CODE
  CODE=$(api_code POST "/api/v2.0/projects/$PNAME/immutabletagrules" "$RULE_FILE")
  if [ "$CODE" != "201" ] && [ "$CODE" != "409" ]; then
    echo "Failed immutable rule for '$PNAME': HTTP $CODE" >&2
    return 1
  fi
}

set_cve_allowlist() {
  local PNAME="$1" PAYLOAD="$2"
  api PUT "/api/v2.0/projects/$PNAME/cve-allowlist" "$PAYLOAD" >/dev/null
  echo "Set CVE allowlist for '$PNAME'" >&2
}

# One object per project. This loop was Nix generating a shell program per
# project, which is what kept it out of a script file.
for i in $(printf '%s' "$PROJECTS_JSON" | jq -r 'keys[]'); do
  proj=$(printf '%s' "$PROJECTS_JSON" | jq ".[$i]")
  name=$(printf '%s' "$proj" | jq -r '.name')

  echo "==> Project: $name"
  printf '%s' "$proj" | jq '.create' >"/tmp/proj-$name.json"

  REG_ID=""
  if [ "$(printf '%s' "$proj" | jq -r '.registry // "null"')" != "null" ]; then
    printf '%s' "$proj" | jq '.registry.payload' >"/tmp/reg-$name.json"
    cred_name=$(printf '%s' "$proj" | jq -r '.registry.credSecret.name // ""')
    if [ -n "$cred_name" ]; then
      cred_key=$(printf '%s' "$proj" | jq -r '.registry.credSecret.key')
      PASSWORD=$(kubectl -n "$NS" get secret "$cred_name" \
        -o "jsonpath={.data.$cred_key}" | base64 -d)
      jq --arg p "$PASSWORD" '.credential.access_secret=$p' "/tmp/reg-$name.json" \
        >"/tmp/reg-$name.json.t" && mv "/tmp/reg-$name.json.t" "/tmp/reg-$name.json"
    fi
    REG_ID=$(ensure_registry "$(printf '%s' "$proj" | jq -r '.registry.name')" "/tmp/reg-$name.json")
    if [ -n "$REG_ID" ]; then
      jq --argjson r "$REG_ID" '.registry_id=$r' "/tmp/proj-$name.json" \
        >"/tmp/proj-$name.json.t" && mv "/tmp/proj-$name.json.t" "/tmp/proj-$name.json"
    fi
  fi

  PID=$(ensure_project "$name" "/tmp/proj-$name.json")
  if [ -z "$PID" ]; then
    echo "ERROR: failed to resolve project id for $name" >&2
    exit 1
  fi

  quota=$(printf '%s' "$proj" | jq -r '.storageQuota')
  if [ "$quota" -ge 0 ]; then
    set_storage_quota "$PID" "$quota"
  fi

  printf '%s' "$proj" | jq -c '.members[]?' | while read -r m; do
    ensure_member "$name" \
      "$(printf '%s' "$m" | jq -r '.entity')" \
      "$(printf '%s' "$m" | jq -r '.entityType')" \
      "$(printf '%s' "$m" | jq -r '.roleId')"
  done

  if [ "$(printf '%s' "$proj" | jq -r '.retention // "null"')" != "null" ]; then
    printf '%s' "$proj" | jq --argjson pid "$PID" '.retention | .scope.ref=$pid' >"/tmp/ret-$name.json"
    set_retention "$PID" "/tmp/ret-$name.json"
  fi

  rule_count=$(printf '%s' "$proj" | jq '.immutableRules | length')
  r=0
  while [ "$r" -lt "$rule_count" ]; do
    printf '%s' "$proj" | jq ".immutableRules[$r]" >"/tmp/imm-$name-$r.json"
    apply_immutable_rule "$name" "/tmp/imm-$name-$r.json"
    r=$((r + 1))
  done

  if [ "$(printf '%s' "$proj" | jq -r '.cveAllowlist // "null"')" != "null" ]; then
    printf '%s' "$proj" | jq '.cveAllowlist' >"/tmp/cve-$name.json"
    set_cve_allowlist "$name" "/tmp/cve-$name.json"
  fi
done
echo "All project bootstraps complete"
