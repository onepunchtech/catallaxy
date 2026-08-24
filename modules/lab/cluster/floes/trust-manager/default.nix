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
  cfg = config.floes.trust-manager;
in
{
  imports = [
    (floeOptions {
      name = "trust-manager";
    })
    ./options.nix
  ];

  options.floes.trust-manager.exports = {

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

  config = lib.mkIf cfg.enable (
    let
      bundlesReadyToken = "trust-manager/bundles/ready";
    in
    {
      floes.trust-manager.network = {
        declared = true;
      };

      floes.trust-manager.imagesComplete = true;

      floes.trust-manager.images.controller = {

        registry = "quay.io";

        repository = "jetstack/trust-manager";

        tag = "v0.22.1";

      };

      floes.trust-manager.images.defaultCAs = {

        registry = "quay.io";

        repository = "jetstack/trust-pkg-debian-bookworm";

        tag = "20230311-deb12u1.6";

      };

      floes.trust-manager.exports.bundleDistribution = {
        readyToken = bundlesReadyToken;
        inherit (cfg) namespace;
        secretTargets = true;
      };

      floes.trust-manager.bundles.trust-manager = {

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

        requires = [ "certificate-issuance/webhook/ready" ];
        provides = [
          bundlesReadyToken
          "kind:trust.cert-manager.io/Bundle"
        ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/trust-manager";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "3m";
        };
      };
    }
  );
}
