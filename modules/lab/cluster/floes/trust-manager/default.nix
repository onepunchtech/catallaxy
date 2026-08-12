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
  name = "trust-manager";
  imports = [ ./options.nix ];
  exports =
    { lib, ... }:
    {

      bundleDistribution = lib.mkOption {
        type = refs.mkCapability {
          readyToken = refs.tokenOption ''"The controller is up and reconciling Bundles."'';
          namespace = lib.mkOption {
            type = lib.types.str;
            description = "Namespace the controller watches for Bundle sources.";
          };
          secretTargets = lib.mkOption {
            type = lib.types.bool;
            description = ''
              Whether Bundles may target Secrets as well as ConfigMaps.
              Without it a `target.secret` Bundle stays silently
              pending: the controller starts with no Secret-write RBAC.
            '';
          };
        };
        default = null;
        description = "Bundle distribution, or null when this floe is off.";
      };
    };
  module =
    { cfg, peers, ... }:
    let

      bundlesReadyToken = "trust-manager/bundles/ready";
    in
    {
      floes.trust-manager.exports.bundleDistribution = {
        readyToken = bundlesReadyToken;
        inherit (cfg) namespace;
        secretTargets = true;
      };

      bundles.trust-manager = {

        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };

        includeInBootstrap = false;
        helmCharts.trust-manager = {
          chart = cfg.chart;
          releaseName = "trust-manager";
          namespace = cfg.namespace;
          values = {
            app.trust.namespace = cfg.namespace;

            secretTargets = {
              enabled = true;

              authorizedSecretsAll = true;
            };
          };
        };

        requires = refs.needs peers.cert-manager.issuance "webhookReady";
        provides = [ bundlesReadyToken ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/trust-manager";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "3m";
        };
      };
    };
})
  __floeModuleArgs
