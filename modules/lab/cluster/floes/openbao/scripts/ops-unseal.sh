set -eu

log() { echo "[openbao] $*" >&2; }

: "${KUBE_CONTEXT:?KUBE_CONTEXT env required}"
: "${BAO_NS:?BAO_NS env required}"

# Read from stdin rather than taking the shares as arguments, so they stay out
# of shell history and out of ps.
if [ -t 0 ]; then
  log "paste unseal keys, one per line, then Ctrl-D:"
fi
shares=$(cat)
[ -n "$shares" ] || {
  log "no keys given"
  exit 1
}

pods=$(kubectl --context "$KUBE_CONTEXT" -n "$BAO_NS" get pods \
  -l app.kubernetes.io/name=openbao -o name)
[ -n "$pods" ] || {
  log "no openbao pods in $BAO_NS"
  exit 1
}

# Every raft node seals independently, so a three-replica vault needs three
# unseals and not one.
for pod in $pods; do
  sealed=$(kubectl --context "$KUBE_CONTEXT" -n "$BAO_NS" exec "$pod" -- \
    bao status -format=json 2>/dev/null | jq -r '.sealed' || echo unknown)
  if [ "$sealed" = "false" ]; then
    log "$pod already unsealed"
    continue
  fi

  printf '%s\n' "$shares" | while IFS= read -r share; do
    [ -n "$share" ] || continue
    printf '%s' "$share" | kubectl --context "$KUBE_CONTEXT" -n "$BAO_NS" \
      exec -i "$pod" -- bao operator unseal - >/dev/null 2>&1 || true
  done

  sealed=$(kubectl --context "$KUBE_CONTEXT" -n "$BAO_NS" exec "$pod" -- \
    bao status -format=json 2>/dev/null | jq -r '.sealed' || echo unknown)
  if [ "$sealed" = "false" ]; then
    log "$pod unsealed"
  else
    log "$pod is still sealed: not enough keys, or the wrong ones"
    exit 1
  fi
done
