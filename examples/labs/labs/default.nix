# THE lab — platform topology and shared ops commands.
# Environment overlays add provisioners and env-specific settings.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  kanidmRef = config.lab.clusters.core.components.kanidm.ref;
in
{
  lab.name = lib.mkDefault "platform";
  lab.dns.zone = lib.mkDefault "homelab.test";

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

  lab.ops.commands = {
    init-user = {
      description = "Reset a kanidm account password (for initial login)";
      args = [
        {
          name = "username";
          description = "The kanidm account name (e.g. lab-admin)";
        }
      ];
      package = pkgs.writeShellApplication {
        name = "init-user";
        runtimeInputs = [ pkgs.kubectl ];
        text = ''
          USER="''${1:?Usage: init-user <username>}"
          CONTEXT="k3d-core"
          NS="${kanidmRef.namespace}"
          POD="kanidm-default-0"

          echo "Resetting password for '$USER'..."
          OUTPUT=$(kubectl --context "$CONTEXT" -n "$NS" exec "$POD" -- \
            kanidmd recover-account "$USER" 2>&1) || {
            echo "Failed:"
            echo "$OUTPUT"
            exit 1
          }

          PASSWORD=$(echo "$OUTPUT" | grep -oP 'new_password: "\K[^"]+' || echo "")

          if [ -z "$PASSWORD" ]; then
            echo "$OUTPUT"
          else
            echo ""
            echo "Account '$USER' password has been reset."
            echo ""
            echo "  Login URL: ${kanidmRef.externalUrl}"
            echo "  Username:  $USER"
            echo "  Password:  $PASSWORD"
            echo ""
            echo "The user should log in and enroll a passkey or change their password."
          fi
        '';
      };
    };

    db-shell = {
      description = "Open a psql shell to the forgejo database";
      category = "database";
      package = pkgs.writeShellApplication {
        name = "db-shell";
        runtimeInputs = [
          pkgs.kubectl
          pkgs.postgresql
        ];
        text = ''
          NS="forgejo"
          CONTEXT="k3d-core"
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
