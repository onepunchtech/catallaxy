set -eu
: "${KUBECONTEXT:?KUBECONTEXT env required}"
: "${MR_NAME:?MR_NAME env required}"

secret_ns=$(kubectl --context "$KUBECONTEXT" \
  get cluster.kubernetes.digitalocean.crossplane.io "$MR_NAME" \
  -o jsonpath='{.spec.writeConnectionSecretToRef.namespace}' 2>/dev/null || true)
secret_name=$(kubectl --context "$KUBECONTEXT" \
  get cluster.kubernetes.digitalocean.crossplane.io "$MR_NAME" \
  -o jsonpath='{.spec.writeConnectionSecretToRef.name}' 2>/dev/null || true)

uuid=""
if [ -n "$secret_ns" ] && [ -n "$secret_name" ]; then
  kubeconfig=$(kubectl --context "$KUBECONTEXT" -n "$secret_ns" \
    get secret "$secret_name" \
    -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d || true)
  if [ -n "$kubeconfig" ]; then
    # A kubeconfig is YAML, so ask it for the server URL rather than hunting
    # a URL-shaped substring anywhere in the document. The old grep would
    # equally have matched a URL in a comment, a `proxy-url`, or a second
    # cluster's entry, and `head -1` made whichever came first authoritative.
    server=$(printf '%s' "$kubeconfig" |
      yq -r '.clusters[0].cluster.server // ""' 2>/dev/null || true)

    # The UUID is the first label of the DOKS API hostname. Take the host out
    # of the URL by its delimiters, then take the label by its.
    host=${server#*://}
    host=${host%%/*}
    host=${host%%:*}
    case "$host" in
    *.k8s.ondigitalocean.com) uuid=${host%%.*} ;;
    *) uuid="" ;;
    esac
  fi
fi

if [ -n "$uuid" ]; then
  printf '%s' "$uuid"
  exit 0
fi

echo "connection secret empty/missing; falling back to DO API name lookup" >&2

do_name=$(kubectl --context "$KUBECONTEXT" \
  get cluster.kubernetes.digitalocean.crossplane.io "$MR_NAME" \
  -o jsonpath='{.spec.forProvider.name}' 2>/dev/null || true)
if [ -z "$do_name" ]; then
  echo "no spec.forProvider.name on Cluster/$MR_NAME: cannot look up by name" >&2
  exit 1
fi

creds_json=$(kubectl --context "$KUBECONTEXT" \
  -n crossplane-system get secret do-credentials \
  -o jsonpath='{.data.credentials}' 2>/dev/null | base64 -d || true)
if [ -z "$creds_json" ]; then
  echo "no crossplane-system/do-credentials secret: cannot call DO API" >&2
  exit 1
fi
token=$(printf '%s' "$creds_json" | jq -r '.token // .access_token // empty')
if [ -z "$token" ]; then
  token=$(kubectl --context "$KUBECONTEXT" \
    -n crossplane-system get secret do-credentials \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
fi
if [ -z "$token" ]; then
  echo "do-credentials secret has no usable token (.credentials.token, .credentials.access_token, or .token)" >&2
  exit 1
fi

resp=$(curl -fsS \
  -H "Authorization: Bearer $token" \
  "https://api.digitalocean.com/v2/kubernetes/clusters?per_page=200" || true)
if [ -z "$resp" ]; then
  echo "DO API list request failed for Cluster/$MR_NAME" >&2
  exit 1
fi
uuid=$(printf '%s' "$resp" |
  jq -r --arg n "$do_name" '.kubernetes_clusters[]? | select(.name == $n) | .id' |
  head -1)
if [ -z "$uuid" ]; then
  echo "DO API has no cluster named '$do_name': resource already destroyed?" >&2
  exit 1
fi
printf '%s' "$uuid"
