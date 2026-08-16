set -eu

log() { echo "[openbao] $*" >&2; }

: "${KUBE_CONTEXT:?KUBE_CONTEXT env required}"
: "${BAO_NS:?BAO_NS env required}"
: "${PROVISION:?PROVISION env required}"

# Port-forwarded rather than run in the cluster, because this prints the
# unseal keys and a pod's stdout is readable by anyone who can read its logs.
# They reach the terminal that asked for them and nowhere else.
port=18200
kubectl --context "$KUBE_CONTEXT" -n "$BAO_NS" port-forward svc/openbao "$port:8200" >/dev/null 2>&1 &
forward=$!
trap 'kill "$forward" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  if curl -sk -o /dev/null "http://127.0.0.1:$port/v1/sys/health?uninitcode=200&sealedcode=200"; then
    break
  fi
  sleep 1
done

BAO_ADDR="http://127.0.0.1:$port" \
  SEAL_MODE=shamir \
  SHARES="${OPT_shares:-5}" \
  THRESHOLD="${OPT_threshold:-3}" \
  NS="$BAO_NS" \
  bash "$PROVISION"
