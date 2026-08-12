{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  cnpg = import ../../../modules/lab/cluster/floes/cnpg;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.cnpg = {
        chart = pkgs.emptyDirectory;
      };
    };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = cnpg;
      cluster.floes.cnpg.enable = false;
    }
  );

  operatorOnlyResult = evalFloe (
    baseArgs
    // {
      floe = cnpg;
      cluster.floes.cnpg.enable = true;
    }
  );

  withClusterResult = evalFloe (
    baseArgs
    // {
      floe = cnpg;
      cluster.floes.cnpg = {
        enable = true;
        clusters.postgres = {
          namespace = "forgejo";
          instances = 2;
          storage.size = "20Gi";
          databases.app = {
            owner = "app";
            extensions = [ "pg_trgm" ];
            schema = {
              image = "registry.test/schema:0.1";
              allowHazards = [ "INDEX_DROPPED" ];
            };
          };
        };
      };
    }
  );

  opBundle = (operatorOnlyResult.config.bundles).cnpg or null;
  clustersBundle = (withClusterResult.config.bundles)."cnpg-clusters" or null;
  clusterResources = if clustersBundle == null then { } else clustersBundle.resources or { };
  clusterCr = clusterResources.postgres or null;
  reconcilerDeploy = clusterResources."postgres-app-schema" or null;
  reconcilerContainer =
    if reconcilerDeploy == null then
      null
    else
      builtins.head reconcilerDeploy.spec.template.spec.containers;
  reconcilerEnvNames =
    if reconcilerContainer == null then [ ] else map (e: e.name) reconcilerContainer.env;

  operatorOnlyClustersResources =
    ((operatorOnlyResult.config.bundles)."cnpg-clusters" or { }).resources or { };
in
lib.runTests {
  testOptionsDeclared = {
    expr = disabledResult.config.floes.cnpg ? enable && disabledResult.config.floes.cnpg ? clusters;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testNamespaceDefaultPreserved = {
    expr = operatorOnlyResult.config.floes.cnpg.namespace;
    expected = "cnpg-system";
  };

  testOperatorBundleEmitted = {
    expr = opBundle != null && opBundle.helmCharts.cnpg.releaseName == "cnpg";
    expected = true;
  };

  testNoClusterResourcesWhenEmpty = {
    expr = operatorOnlyClustersResources;
    expected = { };
  };

  testClusterInstancesPropagate = {
    expr = if clusterCr == null then null else clusterCr.spec.instances;
    expected = 2;
  };

  testSchemaOwnerGetsCreatedb = {
    expr =
      if clusterCr == null then
        [ ]
      else
        map (r: {
          name = r.name;
          createdb = r.createdb;
        }) (clusterCr.spec.managed.roles or [ ]);
    expected = [
      {
        name = "app";
        createdb = true;
      }
    ];
  };

  testPerClusterRefHost = {
    expr = withClusterResult.config.floes.cnpg.clusters.postgres.ref.host;
    expected = "postgres-rw.forgejo.svc.cluster.local";
  };

  testReconcilerEnvWired = {
    expr = reconcilerEnvNames;
    expected = [
      "DATABASE_URL"
      "RECONCILE_INTERVAL"
      "ALLOW_HAZARDS"
    ];
  };
}
