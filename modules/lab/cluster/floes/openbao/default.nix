{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sHelpers,
  lab,
  ...
}:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions refs;
  cfg = config.floes.openbao;
in
{
  imports = [
    (floeOptions {
      name = "openbao";
      version = "0.1.0";
    })
    ./options.nix
  ];

  options.floes.openbao.exports = {
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "openbao";
      description = "Namespace OpenBao runs in.";
    };
    address = lib.mkOption {
      type = lib.types.str;
      default = "http://openbao.openbao.svc.cluster.local:8200";
      description = ''
        In-cluster address of the OpenBao API. This is what
        `lab.secrets.stores.<n>.vault.server` wants: the store is read by
        external-secrets from inside the cluster, not from your machine.
      '';
    };
    externalAddress = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Address of the OpenBao API from outside its own cluster, or empty
        when no domain is set.

        This is the one a *different* cluster wants. `address` is an
        in-cluster DNS name and resolves only where OpenBao runs, so a lab
        whose other clusters read the store has to expose it and use this.
      '';
    };

    sealed = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether OpenBao starts sealed and needs something to unseal it.
        False in `dev` mode, and in `standalone` when `seal` is configured.
        A consumer can read this to decide whether waiting for OpenBao to
        answer is reasonable or whether it will hang until a human acts.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      inherit (lib) optionalAttrs optionals mkIf;

      hcl = import ../../../../../lib/util/hcl.nix { inherit lib; };

      host = "openbao.${cfg.namespace}.svc.cluster.local";
      address = "http://${host}:8200";

      # `seal = { }` is the documented escape hatch for unsealing by hand, and
      # it is not null. Testing nullness alone answered "is a seal configured"
      # with "will anything unseal this", which are different questions: the
      # floe reported an unsealed vault and probed for readiness on one nobody
      # was going to unseal.
      autoUnsealed = cfg.mode == "dev" || (cfg.seal != null && cfg.seal != { });

      # The seal block goes into OpenBao's HCL config. Rendering it from an
      # attrset keeps the option typed rather than making the author write
      # HCL by hand.
      sealHcl =
        if cfg.seal == null then "" else lib.concatStrings (lib.mapAttrsToList (hcl.block "seal") cfg.seal);

      persistent = cfg.mode == "standalone" || cfg.mode == "ha";

      serverConfig = storageBlock: ''
        ui = ${lib.boolToString cfg.ui}

        listener "tcp" {
          tls_disable = 1
          address = "[::]:8200"
          cluster_address = "[::]:8201"
        }

        ${storageBlock}
        ${sealHcl}
      '';

      standaloneConfig = serverConfig ''
        storage "file" {
          path = "/openbao/data"
        }
      '';

      # `service_registration` is what labels the active and standby pods, and
      # the chart's active and standby Services select on those labels. Raft
      # without it elects a leader nothing can address.
      raftConfig = serverConfig ''
        storage "raft" {
          path = "/openbao/data"
        }

        service_registration "kubernetes" {}
      '';

      catalLib = import ../../../../../lib/util/idempotent-job.nix { inherit lib; };

      initSa = "openbao-init";

      # Two Roles because the Job writes into two namespaces: the recovery
      # keys stay beside OpenBao, and the scoped token has to land where
      # external-secrets reads it.
      initRbac = {
        openbao-init-sa = {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = initSa;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
        };
        openbao-init-role = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = initSa;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              verbs = [
                "get"
                "create"
                "update"
                "patch"
              ];
            }
          ];
        };
        openbao-init-rb = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          metadata = {
            name = initSa;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = initSa;
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = initSa;
              namespace = cfg.namespace;
            }
          ];
        };
        openbao-init-token-role = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = "openbao-init-token-writer";
            namespace = cfg.tokenRef.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              verbs = [
                "get"
                "create"
                "update"
                "patch"
              ];
            }
          ];
        };
        openbao-init-token-rb = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          metadata = {
            name = "openbao-init-token-writer";
            namespace = cfg.tokenRef.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "openbao-init-token-writer";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = initSa;
              namespace = cfg.namespace;
            }
          ];
        };
      };

      initJob = catalLib.mkIdempotentJob {
        name = "openbao-init";
        namespace = cfg.namespace;

        contentInputs = {
          inherit (cfg) mode kv;
          replicas = if cfg.mode == "ha" then cfg.replicas else 1;
          token = cfg.tokenRef;
          recovery = cfg.recoveryKeysRef;
        };

        podSpec = {
          serviceAccountName = initSa;
          restartPolicy = "OnFailure";
          containers = [
            {
              name = "init";
              image = cfg.images.init.ref;
              command = [
                "bash"
                "-c"
              ];
              args = [ (builtins.readFile ./scripts/init.sh) ];
              env = [
                {
                  name = "BAO_ADDR";
                  value = address;
                }
                {
                  name = "NS";
                  value = cfg.namespace;
                }
                {
                  name = "KV_PATH";
                  value = cfg.kv.path;
                }
                {
                  name = "KV_VERSION";
                  value = cfg.kv.version;
                }
                {
                  name = "TOKEN_SECRET";
                  value = cfg.tokenRef.name;
                }
                {
                  name = "TOKEN_KEY";
                  value = cfg.tokenRef.key;
                }
                {
                  name = "TOKEN_NS";
                  value = cfg.tokenRef.namespace;
                }
              ]
              ++ optionals (cfg.recoveryKeysRef != null) [
                {
                  name = "RECOVERY_SECRET";
                  value = cfg.recoveryKeysRef.name;
                }
                {
                  name = "RECOVERY_KEY";
                  value = cfg.recoveryKeysRef.key;
                }
              ];
            }
          ];
        };
      };

      # The same script the init Job runs, wrapped for a human. One
      # implementation of the mount, the policy and the token, reached either
      # from inside the cluster or through a port-forward.
      provisionScript = pkgs.writeText "openbao-provision.sh" (builtins.readFile ./scripts/init.sh);

      mkOpsScript =
        { name, text }:
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = with pkgs; [
            kubectl
            curl
            jq
            coreutils
          ];
          text = ''
            export KUBE_CONTEXT="''${KUBECONTEXT:-${config.cluster.ref.kubeContext or ""}}"
            export BAO_NS="${cfg.namespace}"
            export KV_PATH="${cfg.kv.path}"
            export KV_VERSION="${cfg.kv.version}"
            export TOKEN_SECRET="${cfg.tokenRef.name}"
            export TOKEN_KEY="${cfg.tokenRef.key}"
            export TOKEN_NS="${cfg.tokenRef.namespace}"
            export PROVISION="${provisionScript}"
            ${text}
          '';
        };

      opsScripts = {
        initialise = mkOpsScript {
          name = "initialise";
          text = builtins.readFile ./scripts/ops-initialise.sh;
        };
        unseal = mkOpsScript {
          name = "unseal";
          text = builtins.readFile ./scripts/ops-unseal.sh;
        };
        seal-status = mkOpsScript {
          name = "seal-status";
          text = builtins.readFile ./scripts/ops-status.sh;
        };
      };

      exposureResources = k8sHelpers.mkGatewayExposure {
        name = "openbao";
        routeName = "openbao-httproute";
        namespace = cfg.namespace;
        inherit (cfg) domain gateway tls;
        inherit (config.floes.gateway.exports) internalGatewayName;
        sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
        backend = {
          name = "openbao";
          port = 8200;
        };
      };
    in
    {
      assertions = [
        {
          assertion = cfg.mode != "standalone" || cfg.seal != null;
          message = ''
            floes.openbao.mode is "standalone" with no `seal`, so OpenBao will
            start sealed and stay that way until somebody unseals it by hand,
            after every restart.

            Configure `seal` for auto-unseal. Catallaxy will not hold Shamir
            shares for you: OpenBao generates them at init rather than taking
            ones you wrote, and keeping every share in one place is not a
            split at all.

            If unsealing by hand is genuinely what you want, say so with
            `seal = { }`.
          '';
        }
      ];

      # `optionalAttrs` rather than `mkIf`: `description` and `package` have no
      # defaults, so a `mkIf false` would declare the key and leave its
      # required fields undefined, which is an eval error rather than an
      # absent command.
      # The category key is guarded too, not just its contents: an empty
      # `ops.openbao` renders a category branch in the tool that offers
      # nothing. `seal-status` is emitted for every persistent mode, so the
      # set is non-empty exactly when the outer guard holds.
      ops = lib.optionalAttrs persistent {
        openbao = {
          seal-status = {
            description = "Report whether each OpenBao server is initialised and unsealed";
            package = opsScripts.seal-status;
          };
        }
        // lib.optionalAttrs (!autoUnsealed) {
          initialise = {
            description = "Initialise a hand-unsealed OpenBao: print its unseal keys, then mount KV and mint the store token";
            options = {
              shares = {
                description = "How many unseal keys to split the root key into";
                default = "5";
              };
              threshold = {
                description = "How many of them are needed to unseal";
                default = "3";
              };
            };
            package = opsScripts.initialise;
          };

          unseal = {
            description = "Unseal every OpenBao server, reading keys from stdin";
            package = opsScripts.unseal;
          };
        };
      };

      # A sealed vault's pod is never Ready, because the chart's readiness
      # probe is `bao status`. An auto-unsealed one has a bundle probe saying
      # the same thing; a hand-unsealed one has none, so this is the only
      # thing that reports a vault that came back sealed.
      floes.openbao.verify = lib.optionalAttrs persistent {
        unsealed = {
          description = "Every OpenBao server is unsealed and serving";
          expect = {
            apiVersion = "apps/v1";
            kind = "StatefulSet";
            metadata = {
              name = "openbao";
              namespace = cfg.namespace;
            };
            status.readyReplicas = if cfg.mode == "ha" then cfg.replicas else 1;
          };
        };
      };

      floes.openbao.network = {

        declared = true;

        serves.api.port = 8200;

        egress.internet.ports = [ 443 ];

      };

      floes.openbao.imagesComplete = true;

      floes.openbao.images.init = {
        repository = "alpine/k8s";
        tag = "1.32.4";
      };

      floes.openbao.images.server = {
        registry = "quay.io";
        repository = "openbao/openbao";
        tag = "2.3.1";
      };

      floes.openbao.exports = {
        inherit (cfg) namespace;
        inherit address;
        externalAddress = if cfg.domain != "" then "https://${cfg.domain}" else "";
        sealed = !autoUnsealed;
      };

      floes.openbao.bundles.openbao = {
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };

        resources = exposureResources;

        helmCharts.openbao = {
          chart = cfg.chart;
          releaseName = "openbao";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            injector.enabled = false;

            server = {
              image = {
                inherit (cfg.images.server) registry repository tag;
              };

              dev = optionalAttrs (cfg.mode == "dev") {
                enabled = true;
                devRootToken = "$(BAO_DEV_ROOT_TOKEN_ID)";
              };

              standalone = optionalAttrs (cfg.mode == "standalone") {
                enabled = true;
                config = standaloneConfig;
              };

              ha = optionalAttrs (cfg.mode == "ha") {
                enabled = true;
                inherit (cfg) replicas;

                # The chart derives apiAddr from its own scheme helper, which
                # respects tls_disable. clusterAddr it hardcodes to https
                # regardless, so that one has to be said here.
                clusterAddr = "http://$(HOSTNAME).openbao-internal:8201";

                raft = {
                  enabled = true;
                  setNodeId = true;
                  config = raftConfig;
                };

                disruptionBudget.enabled = true;
              };

              dataStorage = optionalAttrs persistent (
                {
                  enabled = true;
                  size = cfg.storage.size;
                }
                // optionalAttrs (cfg.storage.storageClass != null) {
                  storageClass = cfg.storage.storageClass;
                }
              );

              extraSecretEnvironmentVars = optionals (cfg.mode == "dev") [
                {
                  envName = "BAO_DEV_ROOT_TOKEN_ID";
                  secretName = cfg.rootTokenRef.name;
                  secretKey = cfg.rootTokenRef.key;
                }
              ];
            };

            ui.enabled = cfg.ui;
          };
        };

        createNamespaces = [ cfg.namespace ];

        provides = [ "openbao/store/ready" ];

        # Only worth waiting on when something will unseal it. A sealed
        # OpenBao answers health checks with 503 forever, so a probe would
        # burn its timeout and fail the deploy rather than telling anyone
        # what is wrong.
        #
        # A StatefulSet carries no `Available` condition; that is a Deployment
        # condition. Asking for one worked only because the CLI quietly
        # rewrites `Available` on a StatefulSet into this jsonpath, and the
        # renderer behind `mkWaitInitContainer` does not, so the same shape in
        # an init container hangs. Say what is meant.
        #
        # Only dev mode can wait for a Ready pod. Anywhere else the vault is
        # uninitialised at this point and readiness cannot come until the init
        # Job has run, so the wait is that the API answers at all.
        readyProbe = mkIf autoUnsealed (
          if cfg.mode == "dev" then
            {
              kind = "jsonpath";
              resource = "statefulset/openbao";
              namespace = cfg.namespace;
              jsonpath = "{.status.readyReplicas}";
              value = "1";
              timeout = "5m";
            }
          else
            {
              kind = "http";
              url = "${address}/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200";
              namespace = cfg.namespace;
              timeout = "5m";
            }
        );
      };

      # Auto-unseal only. A Shamir vault is sealed the moment it is
      # initialised, and every step after that - mounting KV, writing the
      # policy, minting the token - needs it open. Running anyway would
      # initialise it and then fail on the first sealed call, having consumed
      # the one root token nobody kept. `seal = { }` means you unseal it, and
      # it means you initialise it too.
      floes.openbao.bundles.openbao-init = mkIf (cfg.mode != "dev" && autoUnsealed) {
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };

        resources = initRbac // initJob.resources;
        createNamespaces = [
          cfg.namespace
          cfg.tokenRef.namespace
        ];

        requires = [ "openbao/store/ready" ];

        # The same token a projection provides, so `secret-stores` orders
        # behind it. Without this the ClusterSecretStore can be applied while
        # the Secret it authenticates with does not exist yet.
        provides = [ "secret:${cfg.tokenRef.namespace}/${cfg.tokenRef.name}" ];

        readyProbe = {
          kind = "jsonpath";
          resource = "secret/${cfg.tokenRef.name}";
          namespace = cfg.tokenRef.namespace;
          jsonpath = "{.data.${cfg.tokenRef.key}}";
          timeout = "10m";
        };
      };
    }
  );
}
