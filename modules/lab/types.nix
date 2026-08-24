{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs ? { },
  k8sHelpers ? import ../../lib/k8s-helpers.nix { inherit lib; },
  contracts ? import ../../lib/contracts { inherit lib; },
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    literalExpression
    types
    mkIf
    ;

  outerConfig = config;

  clusterSubmodule = types.submodule (
    { name, config, ... }:
    {
      imports = [
        ./cluster
      ];

      config = {
        cluster.name = lib.mkDefault name;

        _module.args.pkgs = pkgs;
        _module.args.cataCharts = cataCharts;
        _module.args.k8sSpecs = k8sSpecs;
        # Rebuilt per cluster so the probe images come from lab config. The
        # one passed in is constructed before any lab exists.
        _module.args.k8sHelpers = k8sHelpers // {
          wait = (
            import ../../lib/util/wait.nix {
              inherit lib;
              images = lib.mapAttrs (_: i: i.ref) outerConfig.lab.images.wait;
            }
          );
        };
        _module.args.contracts = contracts;
        _module.args.lab = {
          floes = lib.mapAttrs (_: floe: {
            inherit (floe) enable;
            exports = floe.exports or { };
          }) (outerConfig.lab.floes or { });

          name = outerConfig.lab.name;
          environment = outerConfig.lab.environment;
          contextPrefix = outerConfig.lab.contextPrefix;
          clusters = outerConfig.lab.out.allClusters;
          dns = outerConfig.lab.dns;
          network = outerConfig.lab.network;
          registry = outerConfig.lab.registry;
          proxy = outerConfig.lab.proxy;
          bgpRouter = outerConfig.lab.bgpRouter;
          secrets = outerConfig.lab.secrets;

          images = outerConfig.lab.images;

          lint = outerConfig.lab.lint;

          cd = outerConfig.lab.cd;

          policy = outerConfig.lab.policy;
        };
      };
    }
  );

in
{
  options.lab = {
    name = mkOption {
      type = types.str;
      description = "Unique name for this lab";
      example = "homelab";
    };

    prefix = mkOption {
      type = types.str;
      default = "";
      description = ''
        Global name prefix applied to all rendered output.
        Use for multi-tenancy on shared clusters or running multiple lab instances.
        When set, resource names, namespaces, fleet bundles, and ArgoCD apps
        are all prefixed. Empty string = disabled.
      '';
      example = "dev";
    };

    contextPrefix = mkOption {
      type = types.str;
      default = config.lab.name;
      defaultText = literalExpression "config.lab.name";
      example = "platform-local";
      description = ''
        Client-side prefix applied to kubeconfig context names and to the
        k3d cluster name (docker container name). Keeps multi-lab setups
        collision-free: two labs that both declare `cluster.name = "mgmt"`
        get distinct contexts as long as their `lab.name` (or explicit
        `lab.contextPrefix`) differs.

        Defaults to `lab.name`, sanitized. Set to "" to disable prefixing
        entirely (matches catallaxy's pre-contextPrefix behavior). Override
        when the desired prefix should differ from the lab name (e.g. a
        shorter form, or to omit env-specific suffixes carried in
        `lab.name`).

        Distinct from `lab.prefix`: `lab.prefix` prefixes in-cluster
        resource names, namespaces, and gitops artifacts; `lab.contextPrefix`
        affects only client-visible identifiers (kube contexts and the
        k3d cluster docker container names).

        Sanitized at the option boundary: lowercased; '.', '_', '/', and
        spaces collapsed to '-'.
      '';
      apply = s: builtins.replaceStrings [ "." "_" " " "/" ] [ "-" "-" "-" "-" ] (lib.toLower s);
    };

    clusters = mkOption {
      type = types.attrsOf clusterSubmodule;
      default = { };
      description = ''
        Cluster configurations.
        Each cluster is provisioned directly by the CLI (e.g. via k3d for local dev).
        Any cluster can optionally enable CAPI to manage external clusters.
      '';
    };

    environment = mkOption {
      type = types.enum [
        "development"
        "staging"
        "production"
      ];
      default = "development";
      description = ''
        Lab environment. Components can adjust defaults based on this:
        - development: minimal replicas, relaxed resource limits, self-signed TLS
        - staging: moderate replicas, production-like config, self-signed or ACME TLS
        - production: HA replicas, strict resource limits, ACME TLS, destructive ops require --force
      '';
    };

    policy = {
      exposure = {
        defaultTier = mkOption {
          type = types.enum [
            "public"
            "internal"
          ];
          default = "public";
          description = ''
            Network tier every gateway-exposed floe uses unless it sets
            `gateway.tier` explicitly.

            Defaults to `public` to preserve the pre-policy framework
            behaviour. A lab that runs services behind a mesh should set
            this to `internal` ONCE here rather than per floe; that way
            a newly added floe inherits the safe answer instead of
            silently landing on public DNS because someone forgot a
            line.
          '';
        };
      };
    };

    timeouts = {
      waitForResources = mkOption {
        type = types.int;
        default = 600;
        description = ''
          Default timeout in seconds for planner steps that wait on
          resources (e.g. wait-for-resources, wait-for-managed-ready).
          Consumers with slow cloud provisioning (e.g. DOKS on
          production) may need to raise this. Framework code and the
          planner read this value; individual steps may still override
          for known-fast or known-slow operations.
        '';
      };
    };

    destroy = {
      rescueHints = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = literalExpression ''
          {
            "cluster.kubernetes.digitalocean.crossplane.io" =
              "doctl kubernetes cluster list && doctl kubernetes cluster delete <id>";
          }
        '';
        description = ''
          Consumer-supplied hint strings printed verbatim by
          `cata lab destroy` when a Crossplane managed resource of the
          keyed kind is still present on the mgmt cluster after the
          teardown plan completes. Keys are CR kinds
          (`kind.group`, matching the plan's delete step target).
          Values are free-form strings; typically the exact provider
          CLI invocation needed to clean up the cloud-side resource.

          The framework never runs these commands or parses the
          strings. This is the intentional escape hatch for
          provider-specific rescue while keeping catallaxy provider-
          agnostic.
        '';
      };
    };

    cd = {
      strategy = mkOption {
        type = types.enum [
          "kapp"
          "argocd"
          "fleet"
        ];
        default = "kapp";
        description = ''
          CD strategy for delivering manifests to all clusters:
          - kapp: Direct apply via kapp (fast, no git, ideal for local dev)
          - argocd: Render manifests to git, ArgoCD syncs from there
          - fleet: Render manifests to git, Fleet syncs from there
        '';
      };

      bootstrap = mkOption {
        type = types.enum [
          "kubectl-ssa"
          "helm"
          "none"
        ];
        default = "kubectl-ssa";
        description = ''
          Which imperative tool applies the install-target set (bundles
          with `owner.bootstrap = "install-target"`) before argocd can
          reconcile from git. Only meaningful when
          `cd.strategy = "argocd"` (or another pull-based strategy);
          ignored for `cd.strategy = "kapp"` (kapp handles everything
          under that strategy).

          - "kubectl-ssa" (the default): per-phase
            `kubectl apply --server-side --force-conflicts
            --field-manager=catallaxy-bootstrap`. Establishes a
            stable initial field-manager so argocd's later SSA
            transitions ownership cleanly, field-by-field. No
            selector mutation, so no pivot delete needed,
            `owner.steady = "argocd"` bundles migrate in place.

          - "helm": `helm upgrade --install` upstream charts.
            Helm becomes the initial field-manager. Fine when the
            operator already runs helm elsewhere.

          - "none": no-op. Framework verifies the CD controller is
            reachable, else fails with a clear message. Use when
            argocd is installed out-of-band.

          The install-target set; bundles that must exist BEFORE
          argocd can reconcile from git: is bounded regardless of
          bootstrap method: argocd (+ CRDs), forgejo, cert-manager,
          trust-manager, gateway (controller + CRDs), external-secrets,
          reloader, cnpg (forgejo's DB), crossplane (for
          self-provisioning labs). Everything else is created by argocd
          from scratch.

          `cd.strategy = "kapp"` remains fully supported: under that
          strategy every bundle stays imperatively owned by kapp; the
          argocd install-target concept doesn't apply.
        '';
      };

      useOwnerFiltering = mkOption {
        type = types.bool;
        default = false;
        description = ''
          When true, the imperative (kapp / kubectl-ssa / helm) and
          argocd renderers only see bundles whose
          `owner.{bootstrap,steady}` matches: see `bundleType.owner`
          and `cluster.out.{imperativePhases,argocdPhases}`. The CLI's
          pivot-bundle step reconciles any bundle whose bootstrap and
          steady owners differ.

          When false (default), the CD renderers ignore ownership
          and receive the full phase set; current behavior, back-
          compat with labs that haven't tagged any bundles yet.
          Under argocd-strategy this means kapp AND argocd both act
          on every bundle, causing the well-known immutable-selector
          / kapp-label drift.

          Adoption is per-lab. Once the lab has configured bundle
          ownership (via defaults or per-floe), set this to true to
          activate the split.
        '';
      };

      defaultOwner = mkOption {
        type = types.submodule {
          options = {
            bootstrap = mkOption {
              type = types.enum [
                "install-target"
                "argocd"
              ];
              default = "install-target";
              description = ''
                Default `bundle.owner.bootstrap` role for every
                bundle that doesn't declare its own value. See
                `bundleType.owner` for semantics.
              '';
            };
            steady = mkOption {
              type = types.enum [
                "imperative"
                "argocd"
              ];
              default = "imperative";
              description = ''
                Default `bundle.owner.steady` for every bundle that
                doesn't declare its own value. See `bundleType.owner`
                for semantics.
              '';
            };
          };
        };

        default = { };
        description = ''
          Default `bundle.owner` values applied to every bundle
          that doesn't set its own. See `bundleType.owner` for
          per-bundle overrides and install-target → argocd handoff
          semantics.
        '';
      };

      kapp = {
        waitTimeout = mkOption {
          type = types.str;
          default = "10m";
          description = "Timeout waiting for resources to reconcile";
        };
      };

      argocd = {
        repoUrl = mkOption {
          type = types.str;
          default = "";
          description = "Git repository URL for manifest storage";
        };

        targetBranch = mkOption {
          type = types.str;
          default = "main";
          description = "Git branch to commit rendered manifests to";
        };
      };

      fleet = {
        repoUrl = mkOption {
          type = types.str;
          default = "";
          description = "Git repository URL for manifest storage";
        };

        targetBranch = mkOption {
          type = types.str;
          default = "main";
          description = "Git branch to commit rendered manifests to";
        };
      };

      clusterPaths = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Per-cluster targetPath overrides. Key = cluster name, value = path in repo. Default: manifests/<clusterName>";
      };

      git = {
        repo = mkOption {
          type = types.str;
          default = "";
          description = "Git repository URL for publishing rendered manifests (e.g. git@github.com:org/manifests.git)";
        };
        branch = mkOption {
          type = types.str;
          default = "main";
          description = "Target branch for manifest publishing";
        };
        path = mkOption {
          type = types.str;
          default = "";
          description = "Subdirectory within the repo for manifests (empty = repo root)";
        };
        provider = mkOption {
          type = types.enum [
            "github"
            "gitlab"
            "forgejo"
          ];
          default = "github";
          description = "Git provider for PR/MR creation";
        };
        prEnabled = mkOption {
          type = types.bool;
          default = false;
          description = "Create a PR/MR instead of pushing directly to the target branch";
        };
        prBaseBranch = mkOption {
          type = types.str;
          default = "main";
          description = "Base branch for PRs (the branch to merge into)";
        };

        credentialFromKubeSecret = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                context = mkOption {
                  type = types.str;
                  description = "kubectl context of the cluster hosting the credential Secret.";
                };
                namespace = mkOption {
                  type = types.str;
                  description = "Namespace of the Secret.";
                };
                name = mkOption {
                  type = types.str;
                  description = "Secret name.";
                };
                key = mkOption {
                  type = types.str;
                  default = "token";
                  description = "Key inside the Secret's data field holding the access token.";
                };
                username = mkOption {
                  type = types.str;
                  description = ''
                    Username to pair with the access token in
                    basic-auth. For forgejo/gitea machine users this is
                    the login name.
                  '';
                };
              };
            }
          );
          default = null;
          description = ''
            Source of the git basic-auth credential when publishing to
            an in-lab git host. Populated by e.g. the forgejo
            bootstrap component (`components.forgejo.bootstrap`) so
            operators don't need to click through a UI or manage SSH
            keys to complete the gitops handoff.
          '';
        };
      };
    };
  };
}
