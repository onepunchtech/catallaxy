set -eu

# -L because a wave directory is a symlink into the store, and find does not
# descend into one without it. Without this the file list is empty and the
# check passes by having nothing to look at.
files=$(find -L "$MANIFEST_DIR" -name '*.yaml' -type f)

if [ -z "$files" ]; then
  jq -n --arg d "$MANIFEST_DIR" \
    '[{severity: "error", resource: "lint", message: ("no manifests found under " + $d + ", so this check verified nothing")}]'
  exit 0
fi

# shellcheck disable=SC2086
listeners=$(yq -N 'select(.kind == "Gateway") | .spec.listeners[].name' $files | sort -u)

# shellcheck disable=SC2086
routes=$(yq -N -o=tsv '
  select(.kind == "HTTPRoute" or .kind == "TLSRoute")
  | [.kind, .metadata.name, (.spec.parentRefs[].sectionName // "")]
' $files)

findings='[]'
while IFS=$'\t' read -r kind name section; do
  [ -n "${section:-}" ] || continue
  printf '%s\n' "$listeners" | grep -qx -- "$section" && continue
  findings=$(printf '%s' "$findings" | jq \
    --arg r "$kind/$name" \
    --arg m "attaches to Gateway listener '$section', which no Gateway in this cluster declares. A lab with TLS off exports the listener name 'http', not 'https'." \
    '. + [{severity: "error", resource: $r, message: $m}]')
done <<EOF
$routes
EOF

printf '%s' "$findings"
