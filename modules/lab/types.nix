{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs ? { },
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    ;

  # Capture outer (lab-level) config so cluster submodules can access
  # cross-cluster refs and lab-wide settings via the `lab` module arg.
  outerConfig = config;

  clusterSubmodule = types.submodule (
    { name, config, ... }:
    {
      imports = [
        ./cluster
      ];

      config = {
        cluster.name = lib.mkDefault name;

        # Pass lab context to cluster modules as the `lab` argument.
        # This enables cross-cluster refs (e.g. lab.clusters.obs.components.tempo.ref.*)
        # and access to lab-wide settings (dns, network, registry, proxy).
        # Nix lazy evaluation prevents circular dependencies — refs depend only
        # on each cluster's own config.
        _module.args.pkgs = pkgs;
        _module.args.cataCharts = cataCharts;
        _module.args.k8sSpecs = k8sSpecs;
        _module.args.lab = {
          name = outerConfig.lab.name;
          environment = outerConfig.lab.environment;
          clusters = outerConfig.lab.out.allClusters;
          dns = outerConfig.lab.dns;
          network = outerConfig.lab.network;
          registry = outerConfig.lab.registry;
          ingress = outerConfig.lab.ingress;
          bgpRouter = outerConfig.lab.bgpRouter;
          secrets = outerConfig.lab.secrets;
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
      };
    };
  };
}
