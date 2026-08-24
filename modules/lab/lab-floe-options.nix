{ lib }:

let
  inherit (lib) mkOption mkEnableOption types;

  inherit (import ./planner/types.nix { inherit lib; }) declaredStepType;
  infraTypes = import ../../lib/infra/types.nix { inherit lib; };

  opsTypes = import ./ops/types.nix { inherit lib; };
  opsCommandType = opsTypes.opsCommandType { inherit (opsTypes) optionType argType; };
in
{
  labFloeOptions =
    {
      name,
      version ? null,
    }:
    {
      options.lab.floes.${name} = {
        enable = mkEnableOption "the ${name} floe";

        version = mkOption {
          type = types.nullOr types.str;
          default = version;
          description = "Version of what this floe stands up (informational).";
        };

        infra.resources = mkOption {
          type = types.attrsOf infraTypes.resourceType;
          default = { };
          description = ''
            Infrastructure this floe needs provisioned, lifted into the
            lab's stacks under the key it was given here.

            The other camp from `bundles`. A bundle is a Kubernetes resource
            a controller reconciles forever; this is a resource a plan/apply
            tool creates once and records in state. A floe says what it
            needs; the lab says which stack's state records it and which
            credentials reach it.
          '';
        };

        steps = mkOption {
          type = types.attrsOf declaredStepType;
          default = { };
          description = ''
            Plan steps this floe contributes, lifted into `lab.steps` under
            the key it was given here.

            Lab-scope throughout: a step here runs once for the lab, not once
            per cluster, which is why it has no `scope` field. A step that
            acts on one cluster belongs to a cluster floe.
          '';
        };

        ops = mkOption {
          type = types.attrsOf (types.attrsOf opsCommandType);
          default = { };
          description = ''
            Operational commands this floe publishes, keyed by category then
            by name, lifted into `lab.ops.commands`.

            A lab-scope command takes no `--cluster` flag and displaces a
            cluster's of the same category and name, which is what a command
            about the lab's own host services wants.
          '';
        };

        lint = mkOption {
          type = types.attrsOf (import ./lint-types.nix { inherit lib; }).checkType;
          default = { };
          description = ''
            Checks this floe makes about what the lab renders, lifted into
            `lab.lint.checks` and run by `cata lab lint`.

            The static counterpart to `verify`: lint reads what was rendered
            and needs no lab, verify reads a running one.
          '';
        };

        verify = mkOption {
          type = types.attrsOf (import ./verify-types.nix { inherit lib; }).checkType;
          default = { };
          description = ''
            Assertions this floe makes about the lab once it is running,
            lifted into `lab.verify.checks`.

            The floe knows what working means for what it stood up, so it
            says so once here rather than in every lab that enables it.
          '';
        };
      };
    };
}
