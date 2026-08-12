{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  redisOperator = import ../../../modules/lab/cluster/floes/redis-operator;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.redis-operator = {
        chart = pkgs.emptyDirectory;
      };
    };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = redisOperator;
      cluster.floes.redis-operator.enable = false;
    }
  );

  enabledResult = evalFloe (
    baseArgs
    // {
      floe = redisOperator;
      cluster.floes.redis-operator.enable = true;
    }
  );

  bundle = (enabledResult.config.bundles).redis-operator or null;
in
lib.runTests {

  testOptionsDeclared = {
    expr = disabledResult.config.floes.redis-operator ? enable;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testEmitsBundleInOperatorsPhase = {
    expr = bundle != null;
    expected = true;
  };

  testHelmReleaseName = {
    expr = if bundle == null then null else bundle.helmCharts.redis-operator.releaseName;
    expected = "redis-operator";
  };

  testNamespaceDefault = {
    expr = enabledResult.config.floes.redis-operator.namespace;
    expected = "redis-operator";
  };

  testChartDefaults = {
    expr =
      if bundle == null then null else bundle.helmCharts.redis-operator.chart == pkgs.emptyDirectory;
    expected = true;
  };

  testExcludedFromBootstrap = {
    expr = if bundle == null then null else bundle.includeInBootstrap;
    expected = false;
  };

  testCreateNamespaces = {
    expr = if bundle == null then null else bundle.createNamespaces;
    expected = [ "redis-operator" ];
  };
}
