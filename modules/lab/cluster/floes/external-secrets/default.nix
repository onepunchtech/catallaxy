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
  cfg = config.floes.external-secrets;
in
{
  imports = [
    (floeOptions {
      name = "external-secrets";
      version = "0.10.0";
    })
    ./options.nix
  ];

  config = lib.mkIf cfg.enable (
    let
      kappLib = import ../../../../../lib/util/kapp.nix { inherit lib; };
    in
    {

      floes.external-secrets.network = {

        declared = true;

        serves.webhook = {

          port = 443;

          fromApiServer = true;

        };

        reaches = [ "openbao/api" ];

        egress.internet.ports = [ 443 ];

      };

      floes.external-secrets.imagesComplete = true;

      floes.external-secrets.images.controller = {

        registry = "oci.external-secrets.io";

        repository = "external-secrets/external-secrets";

        tag = "v0.15.0";

      };

      floes.external-secrets.bundles.external-secrets-crds = {
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        yamls = [ cataCharts.external-secrets.crds ];
        provides = [
          "external-secrets/crds/established"
          "kind:external-secrets.io/ExternalSecret"
          "kind:external-secrets.io/ClusterExternalSecret"
          "kind:external-secrets.io/SecretStore"
          "kind:external-secrets.io/ClusterSecretStore"
          "kind:external-secrets.io/PushSecret"
          "kind:external-secrets.io/ClusterPushSecret"
          "kind:generators.external-secrets.io/Password"
          "kind:generators.external-secrets.io/UUID"
          "kind:generators.external-secrets.io/Fake"
        ];
      };

      floes.external-secrets.bundles.external-secrets = {

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
    }
  );
}
