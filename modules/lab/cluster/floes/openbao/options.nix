{
  lab,
  lib,
  config,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption types;
  inherit (import ../../../../../lib/floe { inherit lib; }) gatewayOptions;
  contracts = import ../../../../../lib/contracts { inherit lib; };
in
{
  options.floes.openbao = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.openbao.chart;
      description = "Helm chart to install. Defaults to the chart catallaxy pins.";
    };

    mode = mkOption {
      type = types.enum [
        "dev"
        "standalone"
        "ha"
      ];
      default = "dev";
      description = ''
        How OpenBao stores and protects its data.

        `dev` keeps everything in memory and starts unsealed, with a root
        token you supply. Nothing survives a restart, which for a lab's
        runtime store is usually the right trade: the values in it are minted
        by the lab and get minted again on a fresh cluster.

        `standalone` writes to a volume and starts **sealed**. It needs
        `seal` configured to come back on its own; see that option for why
        catallaxy does not automate a Shamir unseal.

        `ha` is `standalone` with raft: `replicas` servers, each with its own
        volume, electing a leader among themselves. Same sealing story.
      '';
    };

    rootTokenRef = {
      name = mkOption {
        type = types.str;
        default = "openbao-root-token";
        description = ''
          Secret holding the root token, in `dev` mode.

          This is a value you author, so it belongs in an authored store and
          reaches the cluster through `secrets.projections` like any other.
          It cannot live in OpenBao, for the obvious reason.
        '';
      };

      key = mkOption {
        type = types.str;
        default = "token";
        description = "Key within that Secret.";
      };
    };

    kv = {
      path = mkOption {
        type = types.str;
        default = "secret";
        description = ''
          Mount path for the KV engine the init Job enables.

          Must match `lab.secrets.stores.<n>.vault.path`. Dev mode mounts this
          for you at `secret`, which is why that is the default on both sides;
          a vault this floe initialises has no mount at all until the Job
          makes one.
        '';
      };

      version = mkOption {
        type = types.enum [
          "1"
          "2"
        ];
        default = "2";
        description = "KV engine version. Must match `lab.secrets.stores.<n>.vault.version`.";
      };
    };

    tokenRef = {
      name = mkOption {
        type = types.str;
        default = "vault-token";
        description = ''
          Secret the init Job writes a scoped token into, for
          external-secrets to authenticate with.

          Must match `lab.secrets.stores.<n>.vault.tokenSecret`. The token is
          not the root token: init mints one carrying a policy over
          `kv.path` and nothing else, then revokes the root token it was
          given.
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
          Namespace the token Secret lands in. It is read by a
          cluster-scoped ClusterSecretStore, so it has to be named.
        '';
      };
    };

    recoveryKeysRef = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              default = "openbao-recovery-keys";
              description = "Secret the recovery keys land in.";
            };
            key = mkOption {
              type = types.str;
              default = "keys";
              description = "Key within it. The value is the JSON array init returned.";
            };
          };
        }
      );
      default = { };
      description = ''
        Where `bao operator init` puts the recovery keys it generates, or null
        to print them to the Job log once and keep them out of the cluster.

        These are not unseal shares, and the distinction is the reason storing
        them is offered at all. Under auto-unseal the KMS credential is what
        stands between an attacker and the data; recovery keys only regenerate
        a root token. Since init revokes the root token it was given, without
        these a lost `tokenRef` Secret means a vault nobody can administer
        again.

        Null is the stricter choice and costs you that recovery path: capture
        them from the Job log at first init or accept losing admin access.

        Inert without auto-unseal. A hand-unsealed vault is initialised by
        `<lab>-ops openbao initialise`, which splits real unseal keys and
        prints them rather than storing them anywhere: those open the vault,
        and the cluster the vault protects is not a place to keep them.
      '';
    };

    seal = mkOption {
      type = types.nullOr types.attrs;
      default = null;
      example = lib.literalExpression ''
        {
          awskms = {
            region = "us-east-1";
            kms_key_id = "alias/openbao-unseal";
          };
        }
      '';
      description = ''
        Auto-unseal configuration, spliced into OpenBao's config as a `seal`
        block. Null leaves the vault sealed on start, which means unsealing it
        by hand after every restart.

        Catallaxy deliberately does not offer to hold Shamir unseal shares for
        you. Two reasons. They are not authorable: OpenBao generates them at
        `operator init`, so you would have to capture them afterwards and
        paste them back, which is the manual step this project keeps trying to
        remove. And putting every share in one place defeats the point of
        splitting them.

        Auto-unseal has neither problem. The KMS or transit credential is a
        value you write ahead of time, so it rides the same projection path as
        everything else, and no unseal key is at rest anywhere.
      '';
    };

    replicas = mkOption {
      type = types.int;
      default = 3;
      description = ''
        How many servers in `ha` mode. Raft wants an odd number so a majority
        is unambiguous, and three is the smallest that survives losing one.
      '';
    };

    storage = {
      size = mkOption {
        type = types.str;
        default = "8Gi";
        description = "Size of each server's volume, in `standalone` and `ha` modes.";
      };

      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "StorageClass for it. Null takes the cluster default.";
      };
    };

    ui = mkOption {
      type = types.bool;
      default = true;
      description = "Serve OpenBao's web UI.";
    };

    domain = mkOption {
      type = types.str;
      default = "";
      description = ''
        Hostname to serve OpenBao on. Empty renders no route, which is the
        right default: a lab's runtime store is reached from inside the
        cluster, and external-secrets never leaves it.
      '';
    };

    tls = {
      issuerRef = contracts.tls.issuerRefOption {
        default = contracts.tls.defaultIssuer config;
        description = "Issuer that signs the serving certificate. Null mints none.";
      };

      secretName = mkOption {
        type = types.str;
        default = "openbao-tls";
        description = "Secret the issued certificate lands in.";
      };
    };

    gateway = gatewayOptions { inherit lab; };
  };
}
