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
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe;
in
(mkFloe {
  name = "openebs";
  version = "4.1.1";
  imports = [ ./options.nix ];
  module =
    { cfg, ... }:
    {
      bundles.openebs = {
        includeInBootstrap = false;
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

        provides = [ "openebs/storage/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "daemonset/openebs-localpv-provisioner";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };
    };
})
  __floeModuleArgs
