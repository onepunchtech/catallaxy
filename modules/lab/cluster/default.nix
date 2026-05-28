{ config, lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  imports = [
    ./auth
    ./components
    ./phases
    ./types.nix
    ./out.nix
    ../provisioners/docker.nix
    ../provisioners/k3d.nix
  ];

  # Standard module system options needed by components
  options.assertions = mkOption {
    type = types.listOf types.unspecified;
    default = [ ];
    internal = true;
  };

  options.warnings = mkOption {
    type = types.listOf types.str;
    default = [ ];
    internal = true;
  };

  # Resource sets, compose services, managed secrets, databases, storage
  # These are used by various components but option declarations are still WIP.
  options.resources = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
  };
  options.compose = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
  };
  # secrets.managed is declared in components/secrets/default.nix
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

  # Lifecycle hooks for cluster teardown. Components contribute ordered steps
  # that run before the cluster is deprovisioned (e.g., CAPI deletes cloud resources).
  options.lifecycle.teardown = mkOption {
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
            description = "Script to execute for this step";
          };
          waitTimeout = mkOption {
            type = types.str;
            default = "5m";
            description = "How long to wait for completion";
          };
        };
      }
    );
    default = [ ];
    description = "Ordered teardown steps executed before cluster deprovisioning";
  };

  # Operational commands contributed by components.
  # These bubble up to lab.ops where same-named commands from different clusters
  # are merged (enum options get their values unioned, packages keyed by cluster).
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
