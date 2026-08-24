{
  pkgs,
  cfg,
  nb,
  mkNetbirdOpsScript,
}:
let
  inherit (nb)
    hasCaBundle
    idpClientId
    idpIssuer
    idpMachineTokenRef
    ;
in
mkNetbirdOpsScript {
  name = "check-config";
  runtimeInputs = with pkgs; [ jq ];
  text = ''
    ISSUER="${idpIssuer}"
    CLIENT_ID="${idpClientId}"
    BOT_TOKEN_NAME="${if idpMachineTokenRef != null then idpMachineTokenRef.name else ""}"
    BOT_TOKEN_NS="${
      if idpMachineTokenRef != null && idpMachineTokenRef.namespace != null then
        idpMachineTokenRef.namespace
      else
        cfg.namespace
    }"
    BOT_TOKEN_KEY="${if idpMachineTokenRef != null then idpMachineTokenRef.key else ""}"
    CA_CM="${if hasCaBundle then cfg.tls.caBundle.name else ""}"
    CA_KEY="${if hasCaBundle then cfg.tls.caBundle.key else "ca.crt"}"

    printf 'netbird preflight for lab %s (ctx=%s, ns=%s)\n\n' \
      "${cfg.domain}" "$KUBE_CONTEXT" "$NB_NS"

    BOT_TOKEN_VAL=$(kubectl --context "$KUBE_CONTEXT" -n "$BOT_TOKEN_NS" \
      get secret "$BOT_TOKEN_NAME" \
      -o jsonpath="{.data.$BOT_TOKEN_KEY}" 2>/dev/null | base64 -d || true)


    printf '  bot token .......... '
    if [ -n "$BOT_TOKEN_VAL" ]; then
      printf 'OK  (%s/%s[%s], %d bytes)\n' \
        "$BOT_TOKEN_NS" "$BOT_TOKEN_NAME" "$BOT_TOKEN_KEY" ''${#BOT_TOKEN_VAL}
    else
      printf 'FAIL\n    → Secret %s/%s[%s] is empty or missing.\n' \
        "$BOT_TOKEN_NS" "$BOT_TOKEN_NAME" "$BOT_TOKEN_KEY"
    fi

    PROBE_POD="netbird-check-config-$$"
    CA_MOUNT=""
    CA_VOL=""
    CACERT_ARG=""
    if [ -n "$CA_CM" ]; then
      CA_MOUNT=',{"name":"ca","mountPath":"/etc/netbird-ca","readOnly":true}'
      CA_VOL=',{"name":"ca","configMap":{"name":"'"$CA_CM"'","items":[{"key":"'"$CA_KEY"'","path":"lab-ca.crt"}]}}'
      CACERT_ARG="--cacert /etc/netbird-ca/lab-ca.crt"
    fi

    printf '  OIDC discovery ..... '
    DISC=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" run "$PROBE_POD" \
      --image="${cfg.images.bootstrap.ref}" \
      --restart=Never --rm -i --quiet \
      --overrides='{"spec":{"containers":[{"name":"probe","image":"${cfg.images.bootstrap.ref}","command":["sh","-c","curl -s '"$CACERT_ARG"' -o /tmp/d -w %{http_code} \"'"$ISSUER"'/.well-known/openid-configuration\" && cat /tmp/d"],"volumeMounts":[{"name":"tmp","mountPath":"/tmp"}'"$CA_MOUNT"']}],"volumes":[{"name":"tmp","emptyDir":{}}'"$CA_VOL"']}}' \
      -- sh -c 'true' 2>/dev/null || true)
    HTTP=$(printf '%s' "$DISC" | tail -c 3)
    BODY=$(printf '%s' "$DISC" | head -c -3)
    if [ "$HTTP" = "200" ]; then
      TOKEN_EP=$(printf '%s' "$BODY" | jq -r '.token_endpoint // empty')
      printf 'OK  (HTTP 200, token_endpoint=%s)\n' "$TOKEN_EP"
    else
      printf 'FAIL (HTTP %s)\n' "$HTTP"
      printf '    → verify idp.issuer resolves and the kanidm OAuth2Client "%s" exists.\n' "$CLIENT_ID"
      TOKEN_EP=""
    fi

    printf '  token exchange ..... '
    if [ -z "$TOKEN_EP" ] || [ -z "$BOT_TOKEN_VAL" ]; then
      printf 'skipped (prior step failed)\n'
    else
      # shellcheck disable=SC2016
      EXCH=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" run "$PROBE_POD-x" \
        --image="${cfg.images.bootstrap.ref}" \
        --restart=Never --rm -i --quiet \
        --env=TOKEN_EP="$TOKEN_EP" \
        --env=CLIENT_ID="$CLIENT_ID" \
        --env=SUBJECT_TOKEN="$BOT_TOKEN_VAL" \
        --overrides='{"spec":{"containers":[{"name":"probe","image":"${cfg.images.bootstrap.ref}","command":["sh","-c","curl -s '"$CACERT_ARG"' -o /tmp/r -w %{http_code} -X POST \"$TOKEN_EP\" -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange -d client_id=\"$CLIENT_ID\" -d subject_token=\"$SUBJECT_TOKEN\" -d subject_token_type=urn:ietf:params:oauth:token-type:access_token && cat /tmp/r"],"volumeMounts":[{"name":"tmp","mountPath":"/tmp"}'"$CA_MOUNT"']}],"volumes":[{"name":"tmp","emptyDir":{}}'"$CA_VOL"']}}' \
        -- sh -c 'true' 2>/dev/null || true)
      XHTTP=$(printf '%s' "$EXCH" | tail -c 3)
      if [ "$XHTTP" = "200" ]; then
        printf 'OK  (HTTP 200)\n'
      else
        printf 'FAIL (HTTP %s)\n' "$XHTTP"
        printf '    → verify kanidm OAuth2Client "%s" has grant_type=token-exchange enabled.\n' "$CLIENT_ID"
        printf '    → verify the bot service-account is a member of the OAuth2Client scope-map groups.\n'
      fi
    fi

    echo ""
    echo "Preflight complete. Fix any FAIL rows before running 'cata lab up'."
  '';
}
