{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions refs;
  cfg = config.floes.kaniop;
in
{
  imports = [
    (floeOptions {
      name = "kaniop";
      version = "0.11.1";
      drift = [
        {
          group = "kaniop.rs";
          kinds = [ "Kanidm" ];
          managedBy = [ "unknown" ];
          reason = "kaniop reconciles the Kanidm CR but registers as `unknown` rather than a real manager name.";
        }
        {
          group = "kaniop.rs";
          kinds = [ "KanidmOAuth2Client" ];
          managedBy = [ "kanidmoauth2clients.kaniop.rs" ];
          reason = "kaniop writes reconciled client state back onto the CR.";
        }
        {
          group = "kaniop.rs";
          kinds = [ "KanidmGroup" ];
          managedBy = [ "kanidmgroups.kaniop.rs" ];
          reason = "kaniop writes reconciled group state back onto the CR.";
        }
        {
          group = "kaniop.rs";
          kinds = [ "KanidmPersonAccount" ];
          managedBy = [ "kanidmpersonsaccounts.kaniop.rs" ];
          reason = "kaniop writes reconciled account state back onto the CR (note the extra `s` in the manager name).";
        }
        {
          group = "kaniop.rs";
          kinds = [ "KanidmServiceAccount" ];
          managedBy = [ "kanidmservicesaccounts.kaniop.rs" ];
          reason = "kaniop writes reconciled account state back onto the CR (note the extra `s` in the manager name).";
        }
      ];
    })
    ./options.nix
  ];

  options.floes.kaniop.exports = {
    operator = lib.mkOption {
      type = refs.mkCapability {
        ready = refs.tokenOption ''"The kaniop controller is running and will reconcile Kanidm CRs."'';
        crdsEstablished = refs.tokenOption ''"The Kanidm CRDs are established": apply a CR before this and the API server rejects the kind.'';
      };
      default = null;
      description = ''
        Kanidm CR reconciliation, or null when this floe is off.
        Consumers assert on this rather than on `floes.kaniop.enable`.
      '';
    };

    operatorReadyProbe = lib.mkOption {
      type = lib.types.attrs;
      default = {
        kind = "condition";
        resource = "deployment/kaniop";
        namespace = "kaniop";
        condition = "Available";
        timeout = "5m";
      };
      description = "Probe a consumer can reuse to wait for the operator, rather than restating the deployment name and namespace.";
    };
  };

  config = lib.mkIf cfg.enable (
    let

      kaniopCrds = pkgs.runCommand "kaniop-crds" { } ''
        cp ${cfg.chart}/crds/crds.yaml $out
      '';
    in
    {
      floes.kaniop.exports.operator = {
        ready = "kaniop/operator/ready";
        crdsEstablished = "kaniop/crds/established";
      };
      floes.kaniop.exports.operatorReadyProbe = {
        kind = "condition";
        resource = "deployment/kaniop";
        namespace = cfg.namespace;
        condition = "Available";
        timeout = "5m";
      };

      floes.kaniop.network = {

        declared = true;

      };

      floes.kaniop.imagesComplete = true;

      floes.kaniop.images.operator = {

        registry = "ghcr.io";

        repository = "pando85/kaniop";

        tag = "0.11.1";

      };

      floes.kaniop.bundles.kaniop-crds = {
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        yamls = [ kaniopCrds ];
        provides = [ "kaniop/crds/established" ];
      };

      floes.kaniop.bundles.kaniop = {
        includeInBootstrap = false;
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        helmCharts.kaniop = {
          chart = cfg.chart;
          releaseName = "kaniop";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            image.tag = cfg.version;
          };
        };
        createNamespaces = [ cfg.namespace ];

        requires = [ "kaniop/crds/established" ];
        provides = [
          "kaniop/operator/ready"
          "identity-operator/ready"
          "kind:kaniop.rs/Kanidm"
          "kind:kaniop.rs/KanidmGroup"
          "kind:kaniop.rs/KanidmOAuth2Client"
          "kind:kaniop.rs/KanidmPersonAccount"
          "kind:kaniop.rs/KanidmServiceAccount"
        ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/kaniop";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };
    }
  );
}
