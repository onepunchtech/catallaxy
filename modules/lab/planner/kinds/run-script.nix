{ lib }:

{
  directions = [
    "deploy"
    "teardown"
  ];
  idempotency = "idempotent";
  dialsLabEndpoints = false;
  dryRunSafe = false;
  params.options = {
    bin = lib.mkOption {
      type = lib.types.str;
      description = ''
        Absolute path to the executable, in practice
        `"''${pkgs.writeShellApplication { ... }}/bin/<name>"`. The lab package
        symlinks it into `$out/hooks/` so Nix retains it as a real runtime
        dependency rather than a string-context ghost.
      '';
    };
    env = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Environment variable to set.";
            };
            secret = lib.mkOption {
              type = lib.types.str;
              description = ''
                `lab.secrets.managed.<secret>` to read. The owning store is
                resolved from that secret's own `store` attribute, the same
                indirection `secrets.projections` uses via its `source` field,
                so the two cannot drift.
              '';
            };
            key = lib.mkOption {
              type = lib.types.str;
              description = "Key within the managed secret.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Environment variables sourced from decrypted managed secrets and
        injected into the subprocess. The executor decrypts every declared
        store before the step loop begins, so a preflight can read a cloud
        credential before any cluster exists. A declared secret missing from
        the decrypted cache fails the step rather than running with the
        variable unset.
      '';
    };
    kubeContext = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Kube context exported to the script. Defaults to the scoped cluster's runtime context.";
    };
  };
}
