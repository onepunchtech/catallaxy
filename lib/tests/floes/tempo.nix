{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  tempo = import ../../../modules/lab/cluster/floes/tempo;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.tempo = {
        chart = pkgs.emptyDirectory;
      };
    };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = tempo;
      cluster.floes.tempo.enable = false;
    }
  );

  fsResult = evalFloe (
    baseArgs
    // {
      floe = tempo;
      cluster.floes.tempo.enable = true;
    }
  );

  s3Result = evalFloe (
    baseArgs
    // {
      floe = tempo;
      cluster.floes.tempo = {
        enable = true;
        storage = {
          type = "s3";
          s3 = {
            bucket = "trace-bucket";
            endpoint = "http://seaweedfs-s3.storage.svc.cluster.local:8333";
            region = "us-west-2";
          };
        };
      };
    }
  );

  fsBundle = (fsResult.config.bundles).tempo or null;
  fsValues = if fsBundle == null then null else fsBundle.helmCharts.tempo.values;
  fsExports = fsResult.config.floes.tempo.exports or { };

  s3Values =
    let
      bundle = (s3Result.config.bundles).tempo or null;
    in
    if bundle == null then null else bundle.helmCharts.tempo.values;
in
lib.runTests {
  testOptionsDeclared = {
    expr = disabledResult.config.floes.tempo ? enable && disabledResult.config.floes.tempo ? storage;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testNamespaceDefault = {
    expr = fsResult.config.floes.tempo.namespace;
    expected = "tempo";
  };

  testBundleInInfrastructurePhase = {
    expr = fsBundle != null && fsBundle.helmCharts.tempo.releaseName == "tempo";
    expected = true;
  };

  testProvidesUrl = {
    expr = fsExports.url or null;
    expected = "http://tempo.tempo.svc.cluster.local:3100";
  };

  testProvidesOtlpGrpc = {
    expr = fsExports.otlpGrpc or null;
    expected = "tempo.tempo.svc.cluster.local:4317";
  };

  testProvidesOtlpHttp = {
    expr = fsExports.otlpHttp or null;
    expected = "http://tempo.tempo.svc.cluster.local:4318";
  };

  testOtlpReceiversEnabled = {
    expr =
      if fsValues == null then
        null
      else
        {
          grpc = fsValues.tempo.receivers.otlp.protocols.grpc.endpoint or null;
          http = fsValues.tempo.receivers.otlp.protocols.http.endpoint or null;
        };
    expected = {
      grpc = "0.0.0.0:4317";
      http = "0.0.0.0:4318";
    };
  };

  testFilesystemStorageBackend = {
    expr = if fsValues == null then null else fsValues.tempo.storage.trace.backend;
    expected = "local";
  };

  testS3StorageWiring = {
    expr =
      if s3Values == null then
        null
      else
        {
          backend = s3Values.tempo.storage.trace.backend;
          bucket = s3Values.tempo.storage.trace.s3.bucket;
          endpoint = s3Values.tempo.storage.trace.s3.endpoint;
          force = s3Values.tempo.storage.trace.s3.forcepathstyle;
        };
    expected = {
      backend = "s3";
      bucket = "trace-bucket";
      endpoint = "http://seaweedfs-s3.storage.svc.cluster.local:8333";
      force = true;
    };
  };

  testRetentionPropagates = {
    expr = if fsValues == null then null else fsValues.tempo.retention;
    expected = "168h";
  };
}
