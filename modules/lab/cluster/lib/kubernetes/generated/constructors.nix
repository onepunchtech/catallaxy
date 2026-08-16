{ lib }:

let
  inherit (lib) mkOption types;

  mkTypedSubmodule =
    {
      options,
      freeformType ? types.attrs,
    }:
    types.submodule {
      inherit options freeformType;
    };

  mkResource =
    {
      apiVersion,
      kind,
      specType ? types.attrs,
    }:
    mkTypedSubmodule {
      options = {
        apiVersion = mkOption {
          type = types.str;
          default = apiVersion;
          description = "Kubernetes API version";
        };

        kind = mkOption {
          type = types.str;
          default = kind;
          description = "Kubernetes resource kind";
        };

        metadata = mkOption {
          type = mkTypedSubmodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "Resource name";
              };
              namespace = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Resource namespace";
              };
              labels = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = "Resource labels";
              };
              annotations = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = "Resource annotations";
              };
            };
          };
          description = "Resource metadata";
        };

        spec = mkOption {
          type = types.nullOr specType;
          default = null;
          description = "Resource specification";
        };
      };
    };
in
{
  inherit mkTypedSubmodule mkResource;
}
