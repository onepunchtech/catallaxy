{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  loki = import ../../../modules/lab/cluster/floes/loki;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.loki = {
        chart = pkgs.emptyDirectory;
      };
    };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = loki;
      cluster.floes.loki.enable = false;
    }
  );

  fsResult = evalFloe (
    baseArgs
    // {
      floe = loki;
      cluster.floes.loki.enable = true;
    }
  );

  s3Result = evalFloe (
    baseArgs
    // {
      floe = loki;
      cluster.floes.loki = {
        enable = true;
        storage = {
          type = "s3";
          s3 = {
            bucket = "custom-bucket";
            endpoint = "http://seaweedfs-s3.storage.svc.cluster.local:8333";
            region = "us-west-2";
          };
        };
      };
    }
  );

  fsBundle = (fsResult.config.bundles).loki or null;
  fsValues = if fsBundle == null then null else fsBundle.helmCharts.loki.values;
  fsExports = fsResult.config.floes.loki.exports or { };

  s3Bundle = (s3Result.config.bundles).loki or null;
  s3Values = if s3Bundle == null then null else s3Bundle.helmCharts.loki.values;
in
lib.runTests {
  testOptionsDeclared = {
    expr = disabledResult.config.floes.loki ? enable && disabledResult.config.floes.loki ? storage;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testNamespaceDefault = {
    expr = fsResult.config.floes.loki.namespace;
    expected = "loki";
  };

  testBundleInInfrastructurePhase = {
    expr = fsBundle != null && fsBundle.helmCharts.loki.releaseName == "loki";
    expected = true;
  };

  testProvidesUrl = {
    expr = fsExports.url or null;
    expected = "http://loki.loki.svc.cluster.local:3100";
  };

  testProvidesPushUrl = {
    expr = fsExports.pushUrl or null;
    expected = "http://loki.loki.svc.cluster.local:3100/loki/api/v1/push";
  };

  testProvidesOtlpUrl = {
    expr = fsExports.otlpUrl or null;
    expected = "http://loki.loki.svc.cluster.local:3100/otlp";
  };

  testFilesystemStorageBucketNames = {
    expr = if fsValues == null then null else fsValues.loki.storage.bucketNames;
    expected = {
      chunks = "chunks";
      ruler = "ruler";
      admin = "admin";
    };
  };

  testSingleBinaryDisablesScaledComponents = {
    expr =
      if fsValues == null then
        null
      else
        {
          read = fsValues.read.replicas;
          write = fsValues.write.replicas;
          backend = fsValues.backend.replicas;
        };
    expected = {
      read = 0;
      write = 0;
      backend = 0;
    };
  };

  testS3StorageWiring = {
    expr =
      if s3Values == null then
        null
      else
        {
          type = s3Values.loki.storage.type;
          chunks = s3Values.loki.storage.bucketNames.chunks;
          endpoint = s3Values.loki.storage.s3.endpoint;
          forcePath = s3Values.loki.storage.s3.s3ForcePathStyle;
        };
    expected = {
      type = "s3";
      chunks = "custom-bucket";
      endpoint = "http://seaweedfs-s3.storage.svc.cluster.local:8333";
      forcePath = true;
    };
  };

  testRetentionPropagates = {
    expr = if fsValues == null then null else fsValues.loki.limits_config.retention_period;
    expected = "744h";
  };
}
