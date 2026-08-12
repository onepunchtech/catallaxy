{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options = {
    name = mkOption {
      type = types.str;
      description = "Resource name. Must be unique within a namespace.";
    };

    namespace = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Namespace for the resource. Null for cluster-scoped resources.";
    };

    labels = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Map of string keys and values for organizing and categorizing objects.";
    };

    annotations = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Arbitrary non-identifying metadata attached to objects.";
    };

    generateName = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional prefix for generated names when name is not specified.";
    };

    finalizers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "List of finalizers that must be empty before the object is deleted.";
    };

    ownerReferences = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            apiVersion = mkOption {
              type = types.str;
              description = "API version of the referent.";
            };
            kind = mkOption {
              type = types.str;
              description = "Kind of the referent.";
            };
            name = mkOption {
              type = types.str;
              description = "Name of the referent.";
            };
            uid = mkOption {
              type = types.str;
              description = "UID of the referent.";
            };
            controller = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "If true, this reference points to the managing controller.";
            };
            blockOwnerDeletion = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "If true, the owner cannot be deleted until this reference is removed.";
            };
          };
          freeformType = types.attrs;
        }
      );
      default = [ ];
      description = "List of objects depended by this object.";
    };
  };

  freeformType = types.attrs;
}
