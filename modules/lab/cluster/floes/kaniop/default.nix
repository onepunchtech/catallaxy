{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
in
(mkFloe {
  name = "kaniop";
  version = "0.11.1";
  imports = [ ./options.nix ];

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

  exports =
    { lib, ... }:
    {
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
      };
    };
  module =
    {
      pkgs,
      cfg,
      ...
    }:
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

      bundles.kaniop-crds = {
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        yamls = [ kaniopCrds ];
        provides = [ "kaniop/crds/established" ];
      };

      bundles.kaniop = {
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
        provides = [ "kaniop/operator/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/kaniop";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };
    };
})
  __floeModuleArgs
