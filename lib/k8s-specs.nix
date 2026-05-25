# lib/k8s-specs.nix
#
# Kubernetes API specs for type generation, and standalone CRD sources
# that aren't coupled to a chart (e.g. gateway-api).
#
# Chart-coupled CRDs live in lib/charts.nix (cataCharts.*.crds).

{
  lib,
  pkgs,
  cataCharts,
}:

let
  specDefs = {
    "1.29" = {
      url = "https://raw.githubusercontent.com/kubernetes/kubernetes/v1.29.15/api/openapi-spec/swagger.json";
      hash = "sha256-hmctk06Li0xJSqBuZlNzzRP6Ko05zjar11iLLHfJLKo=";
    };

    "1.30" = {
      url = "https://raw.githubusercontent.com/kubernetes/kubernetes/v1.30.11/api/openapi-spec/swagger.json";
      hash = "sha256-E38iCX8UbKoxUN7aLszO7B7NC2KAVNGIe/Vfk+cVx8s=";
    };

    "1.31" = {
      url = "https://raw.githubusercontent.com/kubernetes/kubernetes/v1.31.7/api/openapi-spec/swagger.json";
      hash = "sha256-3cs9XD2FhJ8frbVjh9Onv0RxLaKR5b0Is0306KQkf40=";
    };

    "1.32" = {
      url = "https://raw.githubusercontent.com/kubernetes/kubernetes/v1.32.3/api/openapi-spec/swagger.json";
      hash = "sha256-IzW05/ed+FsgBmFksU2PAt0Hfe582Me3+0JQCcmDfoU=";
    };
  };

  specs = lib.mapAttrs (
    version: def:
    pkgs.fetchurl {
      inherit (def) url hash;
      name = "k8s-swagger-${version}.json";
    }
  ) specDefs;

  # Standalone CRD sources (not coupled to any chart)
  standaloneCrdDefs = {
    gateway-api = {
      url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml";
      hash = "sha256-06pnI6MwZ3DP+2Ae4irz012kOs+hylR/wNO84I2tZuc=";
    };
  };

  standaloneCrds = lib.mapAttrs (
    name: def:
    pkgs.fetchurl {
      inherit (def) url hash;
      name = "${name}-crds.yaml";
    }
  ) standaloneCrdDefs;

  # Combined CRDs: chart-coupled + standalone
  # Used by the type generator to produce typed Nix options
  crds =
    (lib.filterAttrs (_: v: v != null) (lib.mapAttrs (_: entry: entry.crds) cataCharts))
    // standaloneCrds;

in
{
  inherit specs crds standaloneCrds;
}
