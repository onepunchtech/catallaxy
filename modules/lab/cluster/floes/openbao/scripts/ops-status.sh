set -eu

: "${KUBE_CONTEXT:?KUBE_CONTEXT env required}"
: "${BAO_NS:?BAO_NS env required}"

pods=$(kubectl --context "$KUBE_CONTEXT" -n "$BAO_NS" get pods \
  -l app.kubernetes.io/name=openbao -o name)
[ -n "$pods" ] || {
  echo "no openbao pods in $BAO_NS" >&2
  exit 1
}

# Per pod, because in HA each raft node is initialised together but sealed
# separately, and one unsealed node is not a working vault.
for pod in $pods; do
  status=$(kubectl --context "$KUBE_CONTEXT" -n "$BAO_NS" exec "$pod" -- \
    bao status -format=json 2>/dev/null || echo '{}')
  printf '%s\t%s\n' "${pod#pod/}" "$(
    printf '%s' "$status" |
      jq -r 'if .initialized == null then "unreachable"
             else "initialised=\(.initialized) sealed=\(.sealed) progress=\(.progress // 0)/\(.t // 0)"
             end'
  )"
done
