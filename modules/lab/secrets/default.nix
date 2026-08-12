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

      kind = mkOption {
        type = types.enum [
          "value"
          "ca"
        ];
        default = "value";
        description = ''
          What kind of secret this is.

          - `value` (default): arbitrary key/value pairs. Generators
            produce independent random strings per key. Today's
            behavior; existing labs don't need to change.

          - `ca`: a self-signed CA cert+key pair. `keys` is
            implicitly `{ "ca.crt" = {}; "ca.key" = {}; }` and the
            pair is minted together by
            `cata lab ops -- trust init-ca` (the cert is signed by
            the same key, so generating them separately doesn't
            compose). Encrypted into the SOPS file as YAML literal
            blocks; written to disk at the paths in `hostPaths`.
        '';
      };

      hostPaths = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = lib.literalExpression ''
          {
            "ca.crt" = "$LAB_STATE_DIR/proxy/ca.crt";
            "ca.key" = "$LAB_STATE_DIR/proxy/ca.key";
          }
        '';
        description = ''
          Per-key absolute host paths. The CLI writes decrypted
          values to these paths during `cata lab up`'s preflight,
          after SOPS decryption succeeds and before service start.
          `*.crt` files are written 0644 (public PEM), everything
          else 0600. Re-runs are idempotent (skip if file content
          already matches the decrypted value).
        '';
      };

      keys = mkOption {
        type = types.attrsOf secretKeyType;
        default = { };
        description = ''
          Source key definitions. These appear in the SOPS file.
          When `kind == "ca"`, this is auto-populated with
          `ca.crt` and `ca.key` if empty; labs shouldn't have to
          repeat the conventional names.
        '';
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
        cluster-level `secrets.projections`. Entries that declare
        `hostPaths` are ALSO projected to disk by the CLI during
        `cata lab up`'s preflight (see `lab.out.hostProjections`).
      '';
    };

    out.hostProjections = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            secretName = mkOption { type = types.str; };
            store = mkOption { type = types.str; };
            key = mkOption { type = types.str; };
            hostPath = mkOption {
              type = types.str;
              description = "Absolute path or path containing $LAB_STATE_DIR (resolved by the CLI at apply time).";
            };
            kind = mkOption {
              type = types.enum [
                "value"
                "ca"
              ];
              default = "value";
            };
          };
        }
      );
      readOnly = true;
      description = ''
        Computed list of (secretName, store, key, hostPath) tuples
        derived from `lab.secrets.managed.<*>.hostPaths`. Each entry
        tells the CLI: take the decrypted value at
        `<store>[<secretName>][<key>]` and write it to `hostPath`
        (with permissions inferred from the path suffix: `*.crt`
        public, everything else 0600).
      '';
    };
  };

  config.lab.secrets.out.hostProjections = lib.concatLists (
    lib.mapAttrsToList (
      name: ms:
      lib.mapAttrsToList (key: path: {
        secretName = name;
        inherit (ms) store kind;
        inherit key;
        hostPath = path;
      }) ms.hostPaths
    ) config.lab.secrets.managed
  );

}
