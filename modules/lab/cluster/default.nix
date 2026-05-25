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

  # Operational commands contributed by components.
  # These bubble up to lab.ops.commands for the generated ops CLI tool.
  options.ops = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          description = mkOption { type = types.str; };
          category = mkOption {
            type = types.str;
            default = "general";
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
          };
          package = mkOption { type = types.package; };
        };
      }
    );
    default = { };
    description = "Operational commands contributed by components (auto-collected by lab.ops)";
  };
}
