{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  seaweedfs = import ../../../modules/lab/cluster/floes/seaweedfs;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.seaweedfs = {
        chart = pkgs.emptyDirectory;
      };
    };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = seaweedfs;
      cluster.floes.seaweedfs.enable = false;
    }
  );

  enabledResult = evalFloe (
    baseArgs
    // {
      floe = seaweedfs;
      cluster.floes.seaweedfs.enable = true;
    }
  );

  customPortResult = evalFloe (
    baseArgs
    // {
      floe = seaweedfs;
      cluster.floes.seaweedfs = {
        enable = true;
        s3.port = 9333;
        volume.storageClass = "fast-ssd";
      };
    }
  );

  bundle = (enabledResult.config.bundles).seaweedfs or null;
  values = if bundle == null then null else bundle.helmCharts.seaweedfs.values;
  exports = enabledResult.config.floes.seaweedfs.exports or { };

  customBundle = (customPortResult.config.bundles).seaweedfs or null;
  customValues = if customBundle == null then null else customBundle.helmCharts.seaweedfs.values;
  customExports = customPortResult.config.floes.seaweedfs.exports or { };
in
lib.runTests {
  testOptionsDeclared = {
    expr =
      disabledResult.config.floes.seaweedfs ? enable
      && disabledResult.config.floes.seaweedfs ? filer
      && disabledResult.config.floes.seaweedfs ? s3;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testNamespaceDefault = {
    expr = enabledResult.config.floes.seaweedfs.namespace;
    expected = "seaweedfs";
  };

  testBundleInInfrastructurePhase = {
    expr = bundle != null && bundle.helmCharts.seaweedfs.releaseName == "seaweedfs";
    expected = true;
  };

  testProvidesS3Endpoint = {
    expr = exports.s3Endpoint or null;
    expected = "http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333";
  };

  testProvidesFilerEndpoint = {
    expr = exports.filerEndpoint or null;
    expected = "http://seaweedfs-filer.seaweedfs.svc.cluster.local:8888";
  };

  testImageOverrideAcrossComponents = {
    expr =
      if values == null then
        null
      else
        {
          master = values.master.imageOverride;
          volume = values.volume.imageOverride;
          filer = values.filer.imageOverride;
          s3 = values.s3.imageOverride;
        };
    expected = {
      master = "chrislusf/seaweedfs:3.71";
      volume = "chrislusf/seaweedfs:3.71";
      filer = "chrislusf/seaweedfs:3.71";
      s3 = "chrislusf/seaweedfs:3.71";
    };
  };

  testNodeSelectorCleared = {
    expr =
      if values == null then
        null
      else
        {
          master = values.master.nodeSelector;
          volume = values.volume.nodeSelector;
          filer = values.filer.nodeSelector;
          s3 = values.s3.nodeSelector;
        };
    expected = {
      master = { };
      volume = { };
      filer = { };
      s3 = { };
    };
  };

  testCustomPortPropagates = {
    expr =
      if customValues == null then
        null
      else
        {
          port = customValues.s3.port;
          endpoint = customExports.s3Endpoint or null;
        };
    expected = {
      port = 9333;
      endpoint = "http://seaweedfs-s3.seaweedfs.svc.cluster.local:9333";
    };
  };

  testVolumeStorageClassPropagates = {
    expr = if customValues == null then null else customValues.volume.storageClass or null;
    expected = "fast-ssd";
  };

  testDbInitConfigMapEmitted = {
    expr =
      if bundle == null then
        false
      else
        (bundle.resources ? seaweedfs-db-init-config)
        && bundle.resources.seaweedfs-db-init-config.kind == "ConfigMap";
    expected = true;
  };
}
