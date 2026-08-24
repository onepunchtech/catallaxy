{
  lib,
  pkgs,
  cfg,
  nb,
  client,
  kubeContext,
}:
let
  inherit (nb) apiTokenSecretName apiTokenSecretKey mgmtExternalUrl;

  mkNetbirdOpsScript =
    {
      name,
      runtimeInputs ? [ ],
      text,
    }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs =
        runtimeInputs
        ++ [
          pkgs.kubectl
          pkgs.coreutils
        ]
        ++ lib.optional pkgs.stdenv.isLinux pkgs.systemd;

      text = ''
        set -eu
        export KUBE_CONTEXT="''${KUBECONTEXT:-${kubeContext}}"
        export NB_NS="${cfg.namespace}"
        export NB_URL="${mgmtExternalUrl}"
        export NB_HOST="${cfg.domain}"
        export NB_CLI="${client.cli}/bin/${cfg.client.serviceName}"
        export NB_DAEMON_UP="${client.daemon}/bin/${cfg.client.serviceName}-daemon"
        export NB_DAEMON_STOP="${client.stop}/bin/${cfg.client.serviceName}-stop"
        ${text}
      '';
    };

  mkApiScript =
    { name, path }:
    mkNetbirdOpsScript {
      inherit name;
      runtimeInputs = with pkgs; [
        curl
        jq
      ];
      text = ''
        PAT=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" \
          get secret ${apiTokenSecretName} \
          -o jsonpath='{.data.${apiTokenSecretKey}}' 2>/dev/null | base64 -d || true)
        if [ -z "$PAT" ]; then
          echo "Operator PAT Secret $NB_NS/${apiTokenSecretName} is empty; bootstrap incomplete." >&2
          exit 1
        fi
        curl -sk -H "Authorization: Token $PAT" "$NB_URL/api/${path}" | jq .
      '';
    };
in
{
  inherit mkNetbirdOpsScript;

  status = mkNetbirdOpsScript {
    name = "status";
    text = ''
      if [ ! -S "${lib.removePrefix "unix://" cfg.client.daemonAddr}" ]; then
        echo ">>> This lab's netbird daemon is not running."
        echo ">>> Join with: cata lab ops -- netbird login"
        exit 1
      fi
      exec "$NB_CLI" status "$@"
    '';
  };

  logout = mkNetbirdOpsScript {
    name = "logout";

    text = ''
      nb() { timeout -k 5 ${toString cfg.client.statusTimeoutSeconds} "$NB_CLI" "$@"; }

      (
        nb down || true
        nb profile select default >/dev/null 2>&1 || true
        ids=$(nb profile list --show-id 2>/dev/null \
          | awk -v n="${cfg.client.profileName}" '$2 == n { print $1 }' || true)
        printf '%s\n' "$ids" | while read -r id; do
          [ -n "$id" ] || continue
          nb profile remove "$id" >/dev/null 2>&1 || true
        done
        echo ">>> Released netbird profile ${cfg.client.profileName}"
      ) || echo ">>> Could not reach the daemon to release its profile; stopping it anyway" >&2

      "$NB_DAEMON_STOP"
      echo ">>> Left the lab mesh and stopped its daemon"
    '';
  };

  peers = mkApiScript {
    name = "peers";
    path = "peers";
  };

  routes = mkApiScript {
    name = "routes";
    path = "routes";
  };
}
