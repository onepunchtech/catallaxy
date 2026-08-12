{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  kaniop = import ../../../modules/lab/cluster/floes/kaniop;

  stubChart = pkgs.runCommand "kaniop-chart-stub" { } ''
    mkdir -p $out/crds
    echo "# stub CRDs" > $out/crds/crds.yaml
  '';

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.kaniop = {
        chart = stubChart;
      };
    };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = kaniop;
      cluster.floes.kaniop.enable = false;
    }
  );

  enabledResult = evalFloe (
    baseArgs
    // {
      floe = kaniop;
      cluster.floes.kaniop.enable = true;
    }
  );

  crdsBundle = (enabledResult.config.bundles).kaniop-crds or null;
  operatorBundle = (enabledResult.config.bundles).kaniop or null;
in
lib.runTests {
  testOptionsDeclared = {
    expr = disabledResult.config.floes.kaniop ? enable;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testNamespaceDefaultPreserved = {
    expr = enabledResult.config.floes.kaniop.namespace;
    expected = "kanidm";
  };

  testCrdsBundleEmitted = {
    expr = crdsBundle != null && lib.length crdsBundle.yamls == 1;
    expected = true;
  };

  testOperatorBundleEmitted = {
    expr = operatorBundle != null && operatorBundle.helmCharts.kaniop.releaseName == "kaniop";
    expected = true;
  };

  testVersionPropagatesToImageTag = {
    expr = if operatorBundle == null then null else operatorBundle.helmCharts.kaniop.values.image.tag;
    expected = "0.11.1";
  };

  testExcludedFromBootstrap = {
    expr = if operatorBundle == null then null else operatorBundle.includeInBootstrap;
    expected = false;
  };
}
