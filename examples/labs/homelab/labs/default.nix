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

  # A runtime store, for values only the running lab can produce. Harbor mints
  # a robot account's credential through its own API after it comes up, so no
  # amount of authoring ahead of time would have it.
  #
  # The lab hosts the store itself, on core. The address is read from the floe
  # rather than restated, so moving OpenBao does not leave this pointing at
  # where it used to be.
  lab.secrets.stores.runtime = {
    backend = "vault";
    vault = {
      # The address that works from obs too. The in-cluster one resolves
      # only inside core, and an assertion refuses it once a second cluster
      # uses the store.
      server = config.lab.clusters.core.floes.openbao.exports.externalAddress;
      tokenSecret.namespace = "external-secrets";
    };
  };

  # The root token OpenBao runs with in dev mode. It is a value you write, so
  # it is authored and projected like any other; it cannot live in the store
  # it unlocks.
  lab.secrets.stores.bootstrap.backend = "env";
  lab.secrets.managed.openbao-root-token = {
    store = "bootstrap";
    # Arbitrary, so there is nothing to choose: `cata secrets generate` mints
    # it. That is the difference between this and the netbird setup key, which
    # some other system issues and a human has to go and fetch.
    keys.token = { };
  };

  lab.steps.verify-lab-dns = {
    kind = "run-script";
    direction = "deploy";
    description = "Check the lab's own DNS answers for the zone before anything dials it";
    before = [ (planTokens.wantsKind "create-cluster") ];
    params.bin = "${
      pkgs.writeShellApplication {
        name = "verify-lab-dns";
        runtimeInputs = [ pkgs.dnsutils ];
        text = ''
          zone="${config.lab.dns.zone}"
          port="${toString config.lab.dns.hostPort}"

          # Asks the lab's DNS directly rather than the host's resolver. The
          # host is not expected to know the zone: it has to be told, with
          # sudo, and everything that reaches a lab hostname goes through the
          # lab's own proxy instead. Testing the host here failed a lab that
          # was working.
          if ! dig +short @127.0.0.1 -p "$port" "argocd.$zone" | grep -q .; then
            echo "the lab's DNS on 127.0.0.1:$port does not answer for *.$zone" >&2
            echo "check the ${config.lab.dns.containerName} container is running" >&2
            exit 1
          fi
          echo "lab DNS answers for *.$zone"
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
      # -L because a wave directory is a symlink into the store, and find does
      # not descend into one without it.
      images=$(find -L "$MANIFEST_DIR" -name '*.yaml' -print0 \
        | xargs -0 -r yq -N -o=json -I0 '.. | select(has("image")) | .image')

      printf '%s\n' "$images" \
        | { grep -E ':latest"?$' || true; } \
        | jq -R 'select(length > 0) | {severity: "error", resource: ., message: "image uses the `latest` tag"}' \
        | jq -s '.'
    '';
  };

  lab.ops.commands.database = {
    shell = {
      description = "Open a psql shell to the forgejo database";
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
