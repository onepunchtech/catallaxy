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
  name = "external-secrets";
  version = "0.10.0";
  imports = [ ./options.nix ];
  module =
    {
      lib,
      cataCharts,
      cfg,
      ...
    }:
    let
      kappLib = import ../../../../../lib/util/kapp.nix { inherit lib; };
    in
    {

      bundles.external-secrets-crds = {
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        yamls = [ cataCharts.external-secrets.crds ];
        provides = [ "external-secrets/crds/established" ];
      };

      bundles.external-secrets = {

        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        helmCharts.external-secrets = {
          chart = cfg.chart;
          releaseName = "external-secrets";
          namespace = cfg.namespace;
          createNamespace = true;

          kustomize = {
            enable = true;
            patches = kappLib.mkPreserveRuntimePatches [
              {
                kind = "Secret";
                name = "external-secrets-webhook";
              }
            ];
          };
          values = lib.recursiveUpdate {
            installCRDs = false;
          } cfg.extraValues;
        };
        createNamespaces = [ cfg.namespace ];

        requires = [ "external-secrets/crds/established" ];
        provides = [ "external-secrets/webhook/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/external-secrets-webhook";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };
    };
})
  __floeModuleArgs
