{
  config,
  pkgs,
  lib,
  ...
}:
let
  coreContext = config.lab.clusters.core.cluster.ref.kubeContext;
  planTokens = import ../../../../lib/plan-tokens.nix { inherit lib; };
in
{
  lab.name = lib.mkDefault "platform";
  lab.dns.zone = lib.mkDefault "homelab.test";

  lab.policy.exposure.defaultTier = lib.mkDefault "public";

  lab.clusters = {
    core =
      { ... }:
      {
        imports = [ ../clusters/core.nix ];
      };
    obs =
      { ... }:
      {
        imports = [ ../clusters/obs.nix ];
      };
  };

  lab.steps.verify-lab-dns = {
    kind = "run-script";
    direction = "deploy";
    description = "Check the host resolves the lab zone before anything dials it over TLS";
    after = [ (planTokens.wants planTokens.lab.hostDns) ];
    before = [ (planTokens.wantsKind "create-cluster") ];
    params.bin = "${
      pkgs.writeShellApplication {
        name = "verify-lab-dns";
        runtimeInputs = [ pkgs.dnsutils ];
        text = ''
          zone="${config.lab.dns.zone}"
          if ! dig +short "argocd.$zone" | grep -q .; then
            echo "host cannot resolve *.$zone" >&2
            echo "run 'cata lab dns --setup', or point your resolver at the lab's CoreDNS" >&2
            exit 1
          fi
          echo "host resolves *.$zone"
        '';
      }
    }/bin/verify-lab-dns";
  };

  lab.lint.checks.no-latest-tag = {
    description = "Container images must not use the floating `latest` tag";
    severity = "error";
    scope = "per-cluster";
    format = "json";
    command = ''
      find "$MANIFEST_DIR" -name '*.yaml' -print0 \
        | xargs -0 yq -o=json -I0 '.. | select(has("image")) | .image' 2>/dev/null \
        | grep -E ':latest"?$' \
        | jq -R '{severity: "error", resource: ., message: "image uses the `latest` tag"}' \
        | jq -s '.'
    '';
  };

  lab.ops.commands = {
    shell = {
      description = "Open a psql shell to the forgejo database";
      category = "database";
      package = pkgs.writeShellApplication {
        name = "shell";
        runtimeInputs = [
          pkgs.kubectl
          pkgs.postgresql
        ];
        text = ''
          NS="forgejo"
          CONTEXT="${coreContext}"
          PASS=$(kubectl --context "$CONTEXT" get secret postgres-app -n "$NS" -o jsonpath='{.data.password}' | base64 -d)
          kubectl --context "$CONTEXT" run -n "$NS" db-shell --rm -it --restart=Never \
            --image=postgres:16 \
            --env="PGPASSWORD=$PASS" \
            -- psql -h postgres-rw -U app -d app
        '';
      };
    };
  };
}
