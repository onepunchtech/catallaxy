# Lab-level secrets: stores and managed secrets.
#
# Stores define WHERE secret values are stored (one SOPS file per store).
# Managed secrets define WHAT values exist, referencing a store.
# Cluster-level projections (in cluster/components/secrets/) define HOW
# managed secrets map to Kubernetes Secrets with optional transforms.
{
  config,
  lib,
  ...
}:

let
  inherit (lib)
    mkOption
    types
    mapAttrsToList
    concatLists
    ;

  secretKeyType = types.submodule {
    options = {
      generator = mkOption {
        type = types.nullOr (
          types.enum [
            "base64"
            "hex"
            "alphanumeric"
            "uuid"
          ]
        );
        default = null;
        description = ''
          Generator for this key's value. null means the value is set
          manually via `cata secrets edit`.
        '';
      };

      length = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Length of generated value";
      };
    };
  };

  storeType = types.submodule {
    options = {
      backend = mkOption {
        type = types.enum [
          "sops"
          "vault"
          "external"
        ];
        default = "sops";
        description = ''
          Storage backend:
          - sops: encrypted YAML files in git
          - vault: HashiCorp Vault (future)
          - external: managed outside catallaxy
        '';
      };
    };
  };

  managedSecretType = types.submodule {
    options = {
      store = mkOption {
        type = types.str;
        description = "Name of the secret store this secret belongs to";
      };

      keys = mkOption {
        type = types.attrsOf secretKeyType;
        default = { };
        description = "Source key definitions — these appear in the SOPS file";
      };
    };
  };
in
{
  options.lab.secrets = {
    stores = mkOption {
      type = types.attrsOf storeType;
      default = { };
      description = ''
        Secret stores. Each store maps to one SOPS file (or one Vault path).
        SOPS files are at: secrets/<lab-name>/<store-name>.enc.yaml
      '';
    };

    managed = mkOption {
      type = types.attrsOf managedSecretType;
      default = { };
      description = ''
        Managed secrets. Each declares source keys that live in a store.
        Components project these into Kubernetes Secrets via
        cluster-level `secrets.projections`.
      '';
    };
  };

}
