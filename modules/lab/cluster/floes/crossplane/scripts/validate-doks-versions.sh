set -eu

pins="${PINS:?PINS env required}"
kubecontext="${KUBECONTEXT:?KUBECONTEXT env required}"

if [ -z "$pins" ]; then
  exit 0
fi

token="${DO_API_TOKEN:-}"

if [ -z "$token" ]; then
  creds_json=$(kubectl --context "$kubecontext" \
    -n crossplane-system get secret do-credentials \
    -o jsonpath='{.data.credentials}' 2>/dev/null | base64 -d || true)
  if [ -n "$creds_json" ]; then
    token=$(printf '%s' "$creds_json" | jq -r '.token // .access_token // empty')
  fi
fi
if [ -z "$token" ]; then
  token=$(kubectl --context "$kubecontext" \
    -n crossplane-system get secret do-credentials \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
fi
if [ -z "$token" ]; then
  echo "validate-doks-versions: no DO token (\$DO_API_TOKEN unset and no do-credentials Secret on '$kubecontext'): skipping" >&2
  exit 0
fi

offered=$(curl -fsS -H "Authorization: Bearer $token" \
  "https://api.digitalocean.com/v2/kubernetes/options" |
  jq -r '.options.versions[]?.slug' || true)
if [ -z "$offered" ]; then
  echo "validate-doks-versions: DO API returned no version list: skipping (network/API issue)" >&2
  exit 0
fi

stale=""
for pin in $pins; do
  cluster="${pin%%=*}"
  version="${pin##*=}"
  if ! printf '%s\n' "$offered" | grep -qxF "$version"; then
    stale="$stale$cluster=$version "
  fi
done

if [ -n "$stale" ]; then
  echo "" >&2
  echo "ERROR: pinned DOKS version(s) no longer offered by DigitalOcean:" >&2
  for pin in $stale; do
    echo "  - $pin" >&2
  done
  echo "" >&2
  echo "DO currently offers:" >&2
  printf '%s\n' "$offered" | sed 's/^/  - /' >&2
  echo "" >&2
  echo "Fix: edit the offending 'version = \"...\";' entries in your" >&2
  echo "consumer's floes.crossplane.digitalocean.kubernetesClusters" >&2
  echo "config to one of the offered slugs, then re-run 'cata lab up'." >&2
  echo "" >&2
  exit 1
fi
