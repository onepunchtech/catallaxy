{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  trustManager = import ../../../modules/lab/cluster/floes/trust-manager;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.trust-manager = {
        chart = pkgs.emptyDirectory;
      };
    };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = trustManager;
      cluster.floes.trust-manager.enable = false;
    }
  );

  enabledResult = evalFloe (
    baseArgs
    // {
      floe = trustManager;
      cluster.floes.trust-manager.enable = true;
    }
  );

  bundle = (enabledResult.config.bundles).trust-manager or null;
in
lib.runTests {
  testOptionsDeclared = {
    expr = disabledResult.config.floes.trust-manager ? enable;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testNamespaceDefaultPreserved = {
    expr = enabledResult.config.floes.trust-manager.namespace;
    expected = "cert-manager";
  };

  testBundleEmitted = {
    expr = bundle != null && bundle.helmCharts.trust-manager.releaseName == "trust-manager";
    expected = true;
  };

  testExcludedFromBootstrap = {
    expr = if bundle == null then null else bundle.includeInBootstrap;
    expected = false;
  };

  testAppTrustNamespaceFollowsNamespace = {
    expr = if bundle == null then null else bundle.helmCharts.trust-manager.values.app.trust.namespace;
    expected = "cert-manager";
  };
}
