# modules/secrets/default.nix
#
# Secrets management — declarative secret definitions with pluggable backends.

{ config, lib, ... }:

let
  inherit (lib) mkOption types;

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
        description = ''
          Length of generated value:
          - base64/hex: number of random bytes (output is longer after encoding)
          - alphanumeric: number of characters
          - uuid: ignored
        '';
      };
    };
  };

  remoteRefType = types.submodule {
    options = {
      store = mkOption {
        type = types.str;
        description = "SecretStore name for external-secrets backend";
      };

      keys = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Mapping of secret key name to remote key path";
      };
    };
  };

  managedSecretType = types.submodule (
    { name, config, ... }:
    {
      options = {
        keys = mkOption {
          type = types.attrsOf secretKeyType;
          default = { };
          description = "Key definitions that form the secret's data";
        };

        namespace = mkOption {
          type = types.str;
          default = "default";
          description = "Kubernetes namespace for this secret";
        };

        phase = mkOption {
          type = types.str;
          default = "secrets";
          description = "Deployment phase for this secret";
        };

        backend = mkOption {
          type = types.enum [
            "sops"
            "external-secrets"
            "vault"
            "external"
          ];
          default = "sops";
          description = ''
            Backend for storing/retrieving this secret:
            - sops: encrypted in git, CLI generates and injects at deploy time
            - external-secrets: generates ExternalSecret CRs for in-cluster operator
            - vault: future — HashiCorp Vault integration
            - external: future — generic external secret manager
          '';
        };

        remoteRef = mkOption {
          type = types.nullOr remoteRefType;
          default = null;
          description = "Remote reference for external-secrets backend";
        };

        ref = mkOption {
          type = types.attrs;
          readOnly = true;
          description = "Computed references for this secret, usable by other modules";
        };
      };

      config.ref = {
        inherit name;
        inherit (config) namespace;
        secretRef = { inherit name; };
        envFrom = {
          secretRef = { inherit name; };
        };
        volume = {
          secret.secretName = name;
        };
      };
    }
  );
in
{
  imports = [
    ./sops.nix
    ./external-secrets.nix
  ];

  options.secrets.managed = mkOption {
    type = types.attrsOf managedSecretType;
    default = { };
    description = "Declarative secret definitions with pluggable backends";
  };
}
