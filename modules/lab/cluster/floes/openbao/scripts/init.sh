set -eu

log() { echo "[openbao-init] $*"; }

: "${BAO_ADDR:?BAO_ADDR env required}"
: "${NS:?NS env required}"
: "${KV_PATH:?KV_PATH env required}"
: "${KV_VERSION:?KV_VERSION env required}"
: "${TOKEN_SECRET:?TOKEN_SECRET env required}"
: "${TOKEN_KEY:?TOKEN_KEY env required}"
: "${TOKEN_NS:?TOKEN_NS env required}"

# `auto` splits recovery keys, which do not unseal anything and exist only to
# regenerate a root token. `shamir` splits real unseal keys, and everything
# after the init call needs the vault open, so this mode has to unseal before
# it can go on.
SEAL_MODE="${SEAL_MODE:-auto}"

api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sk -X "$method" -H "X-Vault-Token: ${BAO_TOKEN:-}" -d "$body" "$BAO_ADDR$path"
  else
    curl -sk -X "$method" -H "X-Vault-Token: ${BAO_TOKEN:-}" "$BAO_ADDR$path"
  fi
}

# An uninitialised OpenBao is never Ready: the chart's readiness probe is
# `bao status`, which fails until the vault is both initialised and unsealed.
# So this waits on the API answering at all, with the query parameters that
# make those two states a 200 rather than a 501 or a 503.
health="$BAO_ADDR/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200&performancestandbycode=200"
while true; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' "$health" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && break
  log "waiting for the API (HTTP $code)"
  sleep 5
done

# Guard on the outcome, not on the precondition. "Is the vault initialised"
# is a different question from "did this Job finish", and answering the first
# meant an interrupted run - evicted pod, dead node - came back, saw an
# initialised vault and exited successfully having mounted nothing and written
# no token. The bundle then waited for a Secret that was never coming.
if kubectl -n "$TOKEN_NS" get secret "$TOKEN_SECRET" \
  -o "jsonpath={.data.$TOKEN_KEY}" >/dev/null 2>&1; then
  log "$TOKEN_NS/$TOKEN_SECRET already exists, leaving alone"
  exit 0
fi

if [ "$(api GET /v1/sys/init | jq -r '.initialized')" = "true" ]; then
  log "the vault is initialised but $TOKEN_NS/$TOKEN_SECRET does not exist."
  log "The root token from that init was never stored and cannot be recovered"
  log "from here. Regenerate one with the keys that init printed"
  log "(bao operator generate-root), then create the KV mount, the"
  log "catallaxy-secrets policy and a token under it by hand."
  exit 1
fi

log "initialising ($SEAL_MODE)"
if [ "$SEAL_MODE" = "shamir" ]; then
  init=$(api PUT /v1/sys/init \
    "{\"secret_shares\":${SHARES:-5},\"secret_threshold\":${THRESHOLD:-3}}")
else
  init=$(api PUT /v1/sys/init '{"recovery_shares":1,"recovery_threshold":1}')
fi

BAO_TOKEN=$(printf '%s' "$init" | jq -r '.root_token')
export BAO_TOKEN
if [ -z "$BAO_TOKEN" ] || [ "$BAO_TOKEN" = "null" ]; then
  log "init returned no root token: $init"
  exit 1
fi

# Printed before anything else can fail. A run that dies further down leaves a
# vault nobody can open, and these are the only way back into it.
keys=$(printf '%s' "$init" | jq -c '.recovery_keys_b64 // .keys_b64 // []')

if [ "$SEAL_MODE" = "shamir" ]; then
  # Never stored, whatever `recoveryKeysRef` says. These open the vault, and
  # keeping them in the cluster the vault protects is not a place to keep
  # them.
  log ""
  log "UNSEAL KEYS. Save these now; they are shown once and stored nowhere."
  printf '%s\n' "$keys" | jq -r '.[]'
  log ""
elif [ -n "${RECOVERY_SECRET:-}" ]; then
  kubectl -n "$NS" create secret generic "$RECOVERY_SECRET" \
    --from-literal="$RECOVERY_KEY=$keys" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "wrote recovery keys to $NS/$RECOVERY_SECRET"
else
  log "recovery keys, stored nowhere, printed once: $keys"
fi

# A Shamir vault is sealed the instant it is initialised, and the mount,
# policy and token calls below all need it open.
if [ "$SEAL_MODE" = "shamir" ]; then
  threshold="${THRESHOLD:-3}"
  i=0
  while [ "$i" -lt "$threshold" ]; do
    share=$(printf '%s' "$keys" | jq -r ".[$i]")
    api PUT /v1/sys/unseal "$(jq -n --arg k "$share" '{key: $k}')" >/dev/null
    i=$((i + 1))
  done
  if [ "$(api GET /v1/sys/seal-status | jq -r '.sealed')" != "false" ]; then
    log "submitted $threshold shares and the vault is still sealed"
    exit 1
  fi
  log "unsealed"
fi

# A vault this Job initialised has no secrets engine at all. Dev mode mounts
# KV for you, which is why nothing in this repo ever needed to.
if api GET /v1/sys/mounts | jq -e --arg p "$KV_PATH/" 'has($p)' >/dev/null; then
  log "kv already mounted at $KV_PATH"
else
  api POST "/v1/sys/mounts/$KV_PATH" \
    "{\"type\":\"kv\",\"options\":{\"version\":\"$KV_VERSION\"}}" >/dev/null
  log "mounted kv v$KV_VERSION at $KV_PATH"
fi

policy=$(
  jq -n --arg p "$KV_PATH" '{policy: ("
    path \"\($p)/*\"          { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] }
    path \"\($p)/data/*\"     { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] }
    path \"\($p)/metadata/*\" { capabilities = [\"read\",\"list\",\"delete\"] }
  ")}'
)
api PUT /v1/sys/policies/acl/catallaxy-secrets "$policy" >/dev/null
log "wrote a policy scoped to $KV_PATH"

scoped=$(
  api POST /v1/auth/token/create \
    '{"policies":["catallaxy-secrets"],"period":"768h"}' |
    jq -r '.auth.client_token'
)
if [ -z "$scoped" ] || [ "$scoped" = "null" ]; then
  log "could not mint a scoped token"
  exit 1
fi

kubectl -n "$TOKEN_NS" create secret generic "$TOKEN_SECRET" \
  --from-literal="$TOKEN_KEY=$scoped" \
  --dry-run=client -o yaml | kubectl apply -f -
log "wrote a scoped token to $TOKEN_NS/$TOKEN_SECRET"

# Nothing holds a root credential afterwards. The recovery keys are what
# regenerates one if it is ever needed again.
api POST /v1/auth/token/revoke-self >/dev/null
log "revoked the initial root token"
