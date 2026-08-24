{
  lib,
  pkgs,
  cfg,
  mkNetbirdOpsScript,
  managementConfigJson,
}:
mkNetbirdOpsScript {
  name = "login";

  text = ''
    if nb_management_connected; then
      echo ">>> Already on the mesh. Management: Connected"
      exit 0
    fi

    "$NB_DAEMON_UP"

    echo ">>> Joining mesh at $NB_URL (SSO via kanidm)"

    EXPECTED_CONFIG_HASH="${
      builtins.substring 0 12 (builtins.hashString "sha256" managementConfigJson)
    }"

    pf_ok=true
    pf_fix() {
      echo ">>> preflight: $1: FAIL" >&2
      echo ">>> fix: $2" >&2
      pf_ok=false
    }
    pf_pass() {
      echo ">>> preflight: $1: ok"
    }

    EXPECTED_MGMT_IMAGE="${cfg.images.management.ref}"
    server_image=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" get deploy netbird-management -o jsonpath='{.spec.template.spec.containers[?(@.name=="netbird-management")].image}' 2>/dev/null || true)
    if [ -z "$server_image" ]; then
      pf_fix "management image matches source" "could not read the live image; check kubectl access to $KUBE_CONTEXT"
    elif [ "$server_image" != "$EXPECTED_MGMT_IMAGE" ]; then
      pf_fix "management image matches source" "live=$server_image expected=$EXPECTED_MGMT_IMAGE. Run 'cata lab up' to reconcile the Deployment"
    else
      pf_pass "management image matches source ($server_image)"
    fi

    # `netbird version` prints one token, `v0.73.1`. Take the last word and
    # drop a leading `v` with parameter expansion rather than spawning awk
    # and sed to do the same two things.
    cli_ver=$("$NB_CLI" version 2>/dev/null | head -1 || true)
    cli_ver="''${cli_ver##* }"
    cli_ver="''${cli_ver#v}"
    if [ -n "$cli_ver" ] && [ "$cli_ver" != "${cfg.client.package.version or ""}" ]; then
      pf_fix "client wrapper is current" "wrapper reports $cli_ver, this tree pins ${
        cfg.client.package.version or "?"
      }. Rebuild the lab package"
    else
      pf_pass "client wrapper is current ($cli_ver)"
    fi

    cm_null=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" get cm netbird-management -o 'jsonpath={.data.management\.tmpl\.json}' 2>/dev/null | grep -c '"DeviceAuthorizationFlow": *null' || true)
    if [ "$cm_null" = "0" ]; then
      pf_fix "configmap has DeviceAuthorizationFlow:null" "ConfigMap is stale. Re-run 'cata --flake .#<lab> lab up' so the netbird-management CM re-applies"
    else
      pf_pass "configmap has DeviceAuthorizationFlow:null"
    fi

    live_hash=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" get deploy netbird-management -o 'jsonpath={.spec.template.metadata.annotations.catallaxy\.io/management-config-hash}' 2>/dev/null || true)
    if [ -z "$live_hash" ]; then
      pf_fix "pod-template config hash present" "Deployment lacks catallaxy.io/management-config-hash annotation. Run 'cata lab up' with this framework version"
    elif [ "$live_hash" != "$EXPECTED_CONFIG_HASH" ]; then
      pf_fix "pod-template config hash matches source" "live=$live_hash expected=$EXPECTED_CONFIG_HASH. Run 'cata lab up' to reconcile the Deployment"
    else
      pf_pass "pod-template config hash ($live_hash)"
    fi

    pod_null=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" exec deploy/netbird-management -c netbird-management -- grep -c '"DeviceAuthorizationFlow": *null' /etc/netbird/management.json 2>/dev/null || echo 0)
    if [ "$pod_null" = "0" ]; then
      pf_fix "pod loaded DeviceAuthorizationFlow:null" "Pod is still running pre-fix config. Force a roll: kubectl --context $KUBE_CONTEXT -n $NB_NS rollout restart deploy/netbird-management"
    else
      pf_pass "pod loaded DeviceAuthorizationFlow:null"
    fi

    if kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" wait --for=condition=available --timeout=5s deploy/netbird-management >/dev/null 2>&1; then
      pf_pass "netbird-management deployment available"
    else
      pf_fix "netbird-management deployment available" "kubectl wait timed out. Inspect: kubectl --context $KUBE_CONTEXT -n $NB_NS describe deploy/netbird-management"
    fi

    if [ "$pf_ok" != "true" ]; then
      echo ">>> preflight failed. See FAIL lines above. Fixing the reported invariant is a prerequisite to a successful 'netbird up'." >&2
      exit 1
    fi
    echo ">>> preflight: all invariants ok"

    cat <<'BANNER'
    >>> Preparing browser-based SSO login for netbird.
    >>> Netbird will print a URL below. Open it in a browser ON THIS MACHINE.
    >>> After you complete the kanidm login, the browser redirects to the
    >>> redirect_uri in that URL, which is one of ${
      lib.concatMapStringsSep ", " toString cfg.client.callbackPorts
    }
    >>> on localhost; netbird takes the first of those that is free.
    >>> Netbird catches that callback and brings the mesh up.
    >>>
    >>> If your terminal is on a remote host (SSH), the browser callback
    >>> won't reach netbird's loopback listener. Either run this from
    >>> your local machine, or SSH forwarding the port the URL names:
    >>>   ssh ${
      lib.concatMapStringsSep " " (p: "-L ${toString p}:localhost:${toString p}") cfg.client.callbackPorts
    } <user>@<host>
    BANNER

    UP_EXIT=0

    if nb_management_connected 5; then
      echo ">>> Already joined. Management: Connected"
      exit 0
    fi

    JOIN_STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S')

    callback_landed() {
      ${
        if pkgs.stdenv.isLinux then
          ''journalctl -u ${cfg.client.serviceName}.service --since "$JOIN_STARTED_AT" --no-pager 2>/dev/null''
        else
          "tail -n 500 ${cfg.client.logFile} 2>/dev/null"
      } | grep -q 'successfully registered on Management Service'
    }

    (
      start=$(date +%s)
      phase=browser
      tick=0
      while :; do
        sleep 5
        tick=$(( tick + 1 ))
        elapsed=$(( $(date +%s) - start ))

        if [ "$phase" = browser ] && callback_landed; then
          phase=mesh
          echo "" >&2
          echo ">>> Login accepted. The callback reached the daemon and the peer" >&2
          echo ">>> is registered. Nothing further is needed from you." >&2
          echo ">>> Bringing the mesh up. \`netbird up\` may still report a" >&2
          echo ">>> deadline here; it stops watching before a cold daemon" >&2
          echo ">>> finishes, and the daemon is what decides." >&2
          echo "" >&2
          tick=0
        fi

        [ $(( tick % 4 )) -eq 0 ] || continue

        if [ "$phase" = browser ]; then
          echo ">>> Waiting for you to finish the browser login… ''${elapsed}s elapsed (window 300s)" >&2
        else
          echo ">>> Bringing the mesh up… ''${elapsed}s elapsed since the login started" >&2
        fi
      done
    ) &
    HEARTBEAT_PID=$!
    UP_STDERR=$(mktemp)
    # shellcheck disable=SC2064
    trap "kill $HEARTBEAT_PID 2>/dev/null || true; rm -f $UP_STDERR" EXIT

    lab_profile_ids() {
      "$NB_CLI" profile list --show-id 2>/dev/null \
        | awk -v n="${cfg.client.profileName}" '$2 == n { print $1 }'
    }

    PROFILE_IDS=$(lab_profile_ids)
    if [ -z "$PROFILE_IDS" ]; then
      "$NB_CLI" profile add "${cfg.client.profileName}" >/dev/null 2>&1 || true
      PROFILE_IDS=$(lab_profile_ids)
    fi

    PROFILE_ID=$(printf '%s\n' "$PROFILE_IDS" | head -1)
    if [ -z "$PROFILE_ID" ] || ! "$NB_CLI" profile select "$PROFILE_ID" >/dev/null 2>&1; then
      echo "!!! could not select netbird profile '${cfg.client.profileName}'." >&2
      echo "!!! \`netbird up\` would act on whichever profile is active, which" >&2
      echo "!!! may belong to another lab. Refusing to continue." >&2
      exit 1
    fi

    printf '%s\n' "$PROFILE_IDS" | tail -n +2 | while read -r dup; do
      [ -n "$dup" ] || continue
      "$NB_CLI" profile remove "$dup" >/dev/null 2>&1 || true
    done

    "$NB_CLI" up --management-url "$NB_URL" ${
      lib.concatStringsSep " " (
        [
          "--interface-name ${cfg.client.interfaceName}"
          "--wireguard-port ${toString cfg.client.wireguardPort}"
        ]
        ++ lib.optional (
          cfg.client.dnsResolverAddress != ""
        ) "--dns-resolver-address ${cfg.client.dnsResolverAddress}"
        ++ cfg.client.extraUpArgs
      )
    } 2>"$UP_STDERR" || UP_EXIT=$?

    kill $HEARTBEAT_PID 2>/dev/null || true
    wait $HEARTBEAT_PID 2>/dev/null || true

    if [ "$UP_EXIT" -eq 0 ]; then
      echo ">>> Login accepted. Confirming with the daemon…" >&2
      if nb_management_connected ${toString cfg.client.statusTimeoutSeconds}; then
        echo ">>> Mesh joined. Management: Connected"
      else
        echo ">>> Mesh joined. The daemon did not answer \`status\` within" >&2
        echo ">>> ${toString cfg.client.statusTimeoutSeconds}s, which it often does not straight after a" >&2
        echo ">>> login; \`netbird up\` succeeded, so the join stands. To look:" >&2
        echo ">>>   journalctl -u ${cfg.client.serviceName}.service" >&2
      fi
      exit 0
    fi

    echo "" >&2
    echo ">>> Login done; waiting for the daemon to finish bringing the mesh up." >&2

    grace_deadline=$(( $(date +%s) + ${toString cfg.client.joinGraceSeconds} ))
    while [ "$(date +%s)" -lt "$grace_deadline" ]; do
      if nb_management_connected 10; then
        echo ">>> Mesh joined. Management: Connected"
        exit 0
      fi
      sleep 5
    done

    echo ""
    echo "!!! netbird up exited $UP_EXIT. This lab is not on the mesh."
    echo "--- netbird up ---"
    cat "$UP_STDERR" >&2 || true
    echo "!!! The daemon's own account of the login follows. Read it before"
    echo "!!! changing anything: 'context deadline exceeded' means no callback"
    echo "!!! reached the flow, which is a different fault from one that"
    echo "!!! reached it and failed."
    echo "--- ${cfg.client.serviceName} daemon log ---"
    ${
      if pkgs.stdenv.isLinux then
        "journalctl -u ${cfg.client.serviceName}.service -n 40 --no-pager 2>&1 || true"
      else
        "tail -n 40 ${cfg.client.logFile} 2>&1 || true"
    }
    echo "---"
    echo "!!! Re-run this step to get a fresh login URL. Only one login flow"
    echo "!!! can be in flight per daemon, so the URL is not re-issued"
    echo "!!! underneath you while you are completing it."
    ${lib.optionalString (cfg.client.logLevel == "info") ''
      echo "!!! For a diagnosable log, set floes.netbird.client.logLevel = \"debug\"."
    ''}
    exit 1
  '';
}
