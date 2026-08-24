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
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions;
  cfg = config.floes.openebs;
in
{
  imports = [
    (floeOptions {
      name = "openebs";
      version = "4.1.1";
    })
    ./options.nix
  ];

  config = lib.mkIf cfg.enable {
    floes.openebs.network = {
      declared = true;
    };

    floes.openebs.imagesComplete = true;

    floes.openebs.images.localPathProvisioner = {
      repository = "rancher/local-path-provisioner";
      tag = "v0.0.28";
    };

    floes.openebs.capabilities.provides.default-storage-class = { };

    floes.openebs.bundles.openebs = {
      includeInBootstrap = false;

      conflicts = [ "default-storage-class" ];
      disableWith = "floes.openebs.enable = false";

      helmCharts.openebs = {
        chart = cfg.chart;
        releaseName = "local-path-provisioner";
        namespace = cfg.namespace;
        createNamespace = true;
        values = {
          storageClass = {
            name = "local-path";
            defaultClass = true;
          };
        };
      };
      createNamespaces = [ cfg.namespace ];

      provides = [
        "openebs/storage/ready"
        "default-storage-class"
      ];
      readyProbe = {
        kind = "condition";
        resource = "daemonset/openebs-localpv-provisioner";
        namespace = cfg.namespace;
        condition = "Available";
        timeout = "5m";
      };
    };
  };
}
