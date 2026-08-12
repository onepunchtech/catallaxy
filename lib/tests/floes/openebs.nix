{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  openebs = import ../../../modules/lab/cluster/floes/openebs;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.local-path-provisioner = {
        chart = pkgs.emptyDirectory;
      };
    };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = openebs;
      cluster.floes.openebs.enable = false;
    }
  );

  enabledResult = evalFloe (
    baseArgs
    // {
      floe = openebs;
      cluster.floes.openebs.enable = true;
    }
  );

  bundle = (enabledResult.config.bundles).openebs or null;
in
lib.runTests {
  testOptionsDeclared = {
    expr =
      disabledResult.config.floes.openebs ? enable
      && disabledResult.config.floes.openebs ? storageClasses;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testBundleEmitted = {
    expr = bundle != null && bundle.helmCharts.openebs.releaseName == "local-path-provisioner";
    expected = true;
  };

  testNamespaceDefault = {
    expr = enabledResult.config.floes.openebs.namespace;
    expected = "openebs";
  };

  testExcludedFromBootstrap = {
    expr = if bundle == null then null else bundle.includeInBootstrap;
    expected = false;
  };

  testStorageClassValues = {
    expr = if bundle == null then null else bundle.helmCharts.openebs.values.storageClass;
    expected = {
      name = "local-path";
      defaultClass = true;
    };
  };

  testEngineDefault = {
    expr = enabledResult.config.floes.openebs.engine;
    expected = "hostpath";
  };
}
