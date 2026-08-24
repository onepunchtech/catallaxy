{ config, lib, ... }:

let
  inherit (lib) mkOption types;

  assertionType = types.submodule {
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
  };
in
{
  imports = [
    ./types.nix
    ./host
    ./network
    ./ops
    ./trust
    ./secrets
    ./images.nix
    ./floes.nix
    ./infra.nix
    ./platforms
    ./lint.nix
    ./verify.nix
    ./e2e.nix
    ./planner
    ./out
  ];

  options.assertions = mkOption {
    type = types.listOf assertionType;
    default = [ ];
    internal = true;
    visible = false;
    description = ''
      Every assertion in the lab, gathered from `lab.assertions` and from
      each `lab.clusters.<n>.assertions`. `lib/eval/module.nix` reads this
      one path and throws on any failure, so a lab that violates a
      constraint fails `nix eval` rather than reaching a cluster.
    '';
  };

  options.lab.assertions = mkOption {
    type = types.listOf assertionType;
    default = [ ];
    description = ''
      Hard config-validity checks at lab scope. A failed entry fails
      evaluation, so it blocks `nix flake check` and every command that
      evaluates the lab. For per-cluster constraints, set
      `lab.clusters.<n>.assertions` instead; that way the constraint
      travels with the module that owns it.
    '';
  };

  config.assertions =
    config.lab.assertions
    ++ lib.concatLists (
      lib.mapAttrsToList (
        clusterName: cluster:
        map (entry: {
          inherit (entry) assertion;
          message = "cluster '${clusterName}': ${entry.message}";
        }) cluster.assertions
      ) config.lab.clusters
    );

  options.lab.warnings = mkOption {
    type = types.listOf types.str;
    default = [ ];
    description = ''
      Soft config-validity advisories at lab scope. Surfaced by
      `cata lint` and `cata lab up` but do not block deployment.
    '';
  };
}
