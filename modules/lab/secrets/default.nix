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

  # Which backends a cluster can write back into. This is what decides how a
  # secret can travel between clusters, so it is derived from the backend
  # rather than declared, and cannot disagree with it.
  runtimeBackends = [
    "vault"
    "external"
  ];

  storeType = types.submodule (
    { config, ... }:
    {
      options = {
        backend = mkOption {
          type = types.enum [
            "sops"
            "env"
            "vault"
            "external"
          ];
          default = "sops";
          description = ''
            Storage backend:
            - sops: encrypted YAML files in git, at
              `secrets/<lab-name>/<store-name>.enc.yaml`
            - env: one environment variable per key, named
              `CATA_SECRET_<STORE>__<SECRET>__<KEY>`, uppercased with every
              character that is not a letter or a digit replaced by an
              underscore. Store `app`, secret `session-key`, key `secret` is
              `CATA_SECRET_APP__SESSION_KEY__SECRET`. The name is derived, so
              there is nothing to declare and nothing to keep in sync. See
              `lab.secrets.envFile` for where the values come from.
            - vault: HashiCorp Vault or OpenBao
            - external: managed outside catallaxy
          '';
        };

        direction = mkOption {
          type = types.enum [
            "authored"
            "runtime"
          ];
          readOnly = true;
          default = if builtins.elem config.backend runtimeBackends then "runtime" else "authored";
          description = ''
            Whether a cluster can publish into this store, derived from
            `backend`.

            `authored` stores are read-only and top-down. You write the value,
            catallaxy decrypts it at deploy and projects it into every cluster
            that needs it. A cluster cannot write back: for `sops` that would
            mean committing to your repository.

            `runtime` stores can be written to, so a secret a cluster mints at
            runtime can reach other clusters through external-secrets.

            The distinction decides how a secret can travel. A value that
            exists before the lab does belongs in an `authored` store and is
            distributed; a value some component mints needs a `runtime` one.
          '';
        };

        writer = {
          command = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            example = [
              "vault-put"
              "--mount"
              "lab"
            ];
            description = ''
              Command the host runs to write one value into this store, as
              argv.

              It receives `CATA_SECRET_KEY` in the environment and the value
              on stdin, and is expected to exit non-zero if the write did not
              happen. Nothing is passed on the command line, so a value never
              reaches a process listing.

              This is what makes the set of stores open. A `vault` store is
              written to over its own API and needs nothing here; anything
              else is a command, so a store catallaxy has never heard of works
              without catallaxy learning about it.

              Required on an `external` store that anything publishes to,
              because `external` otherwise says only that the store is managed
              elsewhere, which is not something to write through.
            '';
          };
        };

        vault = {
          server = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "https://vault.internal";
            description = ''
              Address of the Vault or OpenBao server, as the clusters reach
              it. Required on a `runtime` store that anything publishes to or
              subscribes from, because it is what the generated
              `ClusterSecretStore` dials.
            '';
          };

          path = mkOption {
            type = types.str;
            default = "secret";
            description = "KV mount path.";
          };

          version = mkOption {
            type = types.enum [
              "v1"
              "v2"
            ];
            default = "v2";
            description = "KV engine version.";
          };

          tokenSecret = {
            name = mkOption {
              type = types.str;
              default = "vault-token";
              description = ''
                Secret each cluster holds a Vault token in. It is an ordinary
                Secret, so the usual way to get one there is a projection
                from an `authored` store: sops holds the credential for the
                store, and the store holds the runtime values.
              '';
            };

            key = mkOption {
              type = types.str;
              default = "token";
              description = "Key within that Secret.";
            };

            namespace = mkOption {
              type = types.str;
              default = "external-secrets";
              description = ''
                Namespace the token Secret lives in. A ClusterSecretStore is
                cluster-scoped, so it has to be told.
              '';
            };
          };
        };
      };
    }
  );

  managedSecretType = types.submodule (
    { config, ... }:
    {
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
              produce independent random strings per key.

            - `ca`: a self-signed CA cert+key pair. `keys` always carries
              `ca.crt` and `ca.key`, and `cata secrets generate` mints the
              pair together, because the cert is signed by the same key and
              generating them separately does not compose. Written to disk
              at the paths in `hostPaths`.
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
            Per-key absolute host paths. The CLI writes the values to these
            paths during `cata lab up`'s preflight, after the store loads
            and before any service starts. `*.crt` files are written 0644
            (public PEM), everything else 0600. Re-runs are idempotent
            (skip if file content already matches).
          '';
        };

        keys = mkOption {
          type = types.attrsOf secretKeyType;
          default = { };
          description = ''
            Source key definitions, one entry per value the store holds.
            A `kind = "ca"` secret always carries `ca.crt` and `ca.key`,
            so labs do not repeat the conventional names.
          '';
        };
      };

      config.keys = lib.mkIf (config.kind == "ca") {
        "ca.crt" = { };
        "ca.key" = { };
      };
    }
  );
in
{

  options.lab.secrets = {
    stores = mkOption {
      type = types.attrsOf storeType;
      default = { };
      description = ''
        Secret stores. Where a store's keys live is its `backend`: a SOPS
        file at `secrets/<lab-name>/<store-name>.enc.yaml`, environment
        variables, or somewhere outside catallaxy.
      '';
    };

    envFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "examples/labs/gitops/envs/ci.env";
      description = ''
        File that sets the variables an `env` backed store reads, as a path
        relative to the flake root. A runner loads it with
        `set -a; . "$flake/$file"; set +a` before the lab starts, so every
        assignment in it becomes an environment variable.

        A relative path rather than a Nix path on purpose. A Nix path
        resolves to the flake's source in the store, which under lazy trees
        is a name for something that was never written to disk, so the
        runner is handed a path that does not exist. The repository is where
        the file actually is, and a relative path is also what a human can
        act on: it is the argument to `git add`.

        Catallaxy never reads this file. The environment is the interface;
        this only names one way to fill it, and names it where a runner can
        find it without being told.

        A lab whose managed secrets live in an `env` store and which sets no
        `envFile` is not self-contained, because the values then have to
        arrive from somewhere the lab does not describe.
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
            secretName = mkOption {
              type = types.str;
              description = "Managed secret the value comes from.";
            };
            store = mkOption {
              type = types.str;
              description = "Store that secret lives in.";
            };
            key = mkOption {
              type = types.str;
              description = "Key within the secret.";
            };
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
              description = ''
                Carried through from the managed secret, because a `ca` is
                written with different permissions than an opaque value.
              '';
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

  config.lab.assertions =
    let
      declaredStores = lib.concatStringsSep ", " (lib.attrNames config.lab.secrets.stores);
    in
    lib.mapAttrsToList (name: ms: {
      assertion = config.lab.secrets.stores ? ${ms.store};
      message = ''
        lab.secrets.managed.${name}.store is "${ms.store}", which is not one
        of the declared stores (${declaredStores}). The store decides where
        the keys live, so a name with no store behind it has no backend
        to read.
      '';
    }) config.lab.secrets.managed;

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
