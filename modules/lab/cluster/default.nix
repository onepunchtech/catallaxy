{ config, lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  imports = [
    ./apiserver
    ./floes
    ./bundles.nix
    ./shell.nix
    ./steps.nix
    ./verify.nix
    ./types.nix
    ./drift.nix
    ./out.nix
    ./security.nix
    ./coredns-internal.nix
    ./secrets.nix
    ../provisioners/docker.nix
    ../provisioners/k3d.nix
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
      Hard config-validity checks. Failed entries block `cata lab up`.
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
  };
  options.compose = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
  };
  options.databases.postgres = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
  };
  options.databases.redis = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
  };
  options.storage.s3Buckets = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
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
      types.submodule {
        options = {
          description = mkOption { type = types.str; };
          category = mkOption {
            type = types.str;
            default = "general";
            description = "Subcommand group (e.g. 'backup', 'database')";
          };
          options = mkOption {
            type = types.attrsOf (
              types.submodule {
                options = {
                  type = mkOption {
                    type = types.enum [
                      "string"
                      "enum"
                      "bool"
                    ];
                    default = "string";
                  };
                  description = mkOption {
                    type = types.str;
                    default = "";
                  };
                  required = mkOption {
                    type = types.bool;
                    default = false;
                  };
                  default = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                  };
                  values = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Valid values for enum type";
                  };
                };
              }
            );
            default = { };
            description = "Named options (flags) for this command";
          };
          args = mkOption {
            type = types.listOf (
              types.submodule {
                options = {
                  name = mkOption { type = types.str; };
                  description = mkOption {
                    type = types.str;
                    default = "";
                  };
                  required = mkOption {
                    type = types.bool;
                    default = true;
                  };
                };
              }
            );
            default = [ ];
            description = "Positional arguments";
          };
          package = mkOption { type = types.package; };
        };
      }
    );
    default = { };
    description = "Operational commands contributed by components (auto-collected by lab.ops)";
  };
}
