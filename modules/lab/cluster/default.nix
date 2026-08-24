{ config, lib, ... }:

let
  inherit (lib) mkOption types;
  opsTypes = import ../ops/types.nix { inherit lib; };
  inherit (import ../../../lib/floe/collisions.nix { inherit lib; }) contestedKeys;

  enabledFloes = lib.filterAttrs (_: floe: floe.enable or false) config.floes;

  contestedOps = contestedKeys {
    floes = config.floes;
    keysOf =
      floe:
      lib.concatMap (category: map (name: "${category} ${name}") (lib.attrNames floe.ops.${category})) (
        lib.attrNames (floe.ops or { })
      );
  };
in
{
  imports = [
    ./apiserver
    ./floes
    ./bundles.nix
    ./infra.nix
    ./prerequisites.nix
    ./capabilities.nix
    ./shell.nix
    ./steps.nix
    ./verify.nix
    ./lint.nix
    ./types.nix
    ./drift.nix
    ./out.nix
    ./security.nix
    ./coredns-internal.nix
    ./secrets.nix
    ./secrets-generate.nix
    ../provisioners/docker.nix
    ../provisioners/k3d.nix
    ../provisioners/talos.nix
  ];

  options.assertions = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          assertion = mkOption {
            type = types.bool;
            description = "True = check passes. False = violation reported.";
          };
          message = mkOption {
            type = types.str;
            description = ''
              Diagnostic shown when the assertion fails. Mention the
              offending option path and what the user should change.
            '';
          };
        };
      }
    );
    default = [ ];
    description = ''
      Hard config-validity checks. A failed entry fails evaluation of the
      whole lab, so it blocks `nix flake check` and every command that
      evaluates it, not just `cata lab up`.
    '';
  };

  options.warnings = mkOption {
    type = types.listOf types.str;
    default = [ ];
    description = ''
      Soft config-validity advisories. Surfaced via `cata lint` /
      `cata lab up` but do not block deployment.
    '';
  };

  options.resources = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
    description = "Extra Kubernetes resources to render into this cluster, keyed by name. An escape hatch for something no floe covers.";
  };

  options.lifecycle.preProvision = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Step name for display";
          };
          description = mkOption {
            type = types.str;
            default = "";
            description = "What this step does, shown in `cata lab plan`.";
          };
          order = mkOption {
            type = types.int;
            default = 0;
            description = "Execution order (lower = first)";
          };
          package = mkOption {
            type = types.package;
            description = ''
              Package whose `bin/<step-name>` is invoked. Non-zero
              exit aborts provisioning; the step's stderr is shown
              verbatim, so write a clear remediation message.
            '';
          };
        };
      }
    );
    default = [ ];
    description = ''
      Ordered pre-provision steps executed before the cluster is
      created. Each step is a package; the CLI invokes
      `<package>/bin/<step-name>`. Non-zero exit aborts.
    '';
  };

  options.ops = mkOption {
    type = types.attrsOf (
      types.attrsOf (
        opsTypes.opsCommandType {
          inherit (opsTypes) optionType argType;
        }
      )
    );
    default = { };
    description = ''
      Operational commands contributed by components, keyed by category then
      by name to match the `<lab>-ops <category> <name>` invocation.

      Keyed by name alone, two floes could not both publish a `status`: the
      submodule's required fields collided before anything reached the
      aggregator, and the category was only a field it carried.
    '';
  };

  config.ops = lib.mkMerge (lib.mapAttrsToList (_: floe: floe.ops) enabledFloes);

  config.assertions = lib.mapAttrsToList (pair: claimants: {
    assertion = false;
    message = ''
      ops command `${pair}` on cluster '${config.cluster.name}' is published
      by ${lib.concatStringsSep " and " (map (n: "`floes.${n}`") claimants)}.

      A category and a name together are how the generated tool addresses a
      command, so the second publisher does not add one, it collides with
      the first on the fields the two disagree about.

      Give one of them its own category, which is what the pair is for: two
      floes may both publish a `status`, and `<lab>-ops <category> status`
      still says which.
    '';
  }) contestedOps;
}
