{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  prometheus = import ../../../modules/lab/cluster/floes/prometheus;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.prometheus = {
        chart = pkgs.emptyDirectory;
        crds = "prometheus-crds-stub";
      };
    };
  };

  stubUpstream =
    { lib, ... }:
    {
      config._module.freeformType = lib.types.attrs;
      options.floes.gateway.exports = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      options.floes.gateway.internalHostnames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      config.floes.gateway.exports.internalGatewayName = "stub-internal";
      config.floes.gateway.exports.gatewayName = "stub-gateway";
      config.floes.gateway.exports.defaultTier = "public";
      config.floes.gateway.exports.namespace = "kube-system";
    };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = prometheus;
      cluster = {
        imports = [ stubUpstream ];
        floes.prometheus.enable = false;
      };
    }
  );

  basicResult = evalFloe (
    baseArgs
    // {
      floe = prometheus;
      cluster = {
        imports = [ stubUpstream ];
        floes.prometheus.enable = true;
      };
    }
  );

  gatewayResult = evalFloe (
    baseArgs
    // {
      floe = prometheus;
      cluster = {
        imports = [ stubUpstream ];
        floes.prometheus = {
          enable = true;
          gateway = {
            enable = true;
            domain = "prometheus-rw.test.local";
          };
        };
      };
    }
  );

  internalResult = evalFloe (
    baseArgs
    // {
      floe = prometheus;
      cluster = {
        imports = [ stubUpstream ];
        floes.prometheus = {
          enable = true;
          gateway = {
            enable = true;
            domain = "prometheus-rw.internal.test";
            tier = "internal";
          };
        };
      };
    }
  );

  basicBundle = (basicResult.config.bundles).prometheus or null;
  basicValues = if basicBundle == null then null else basicBundle.helmCharts.prometheus.values;
  basicExports = basicResult.config.floes.prometheus.exports or { };

  crdsBundle = (basicResult.config.bundles).prometheus-crds or null;

  gatewayResources =
    let
      bundle = (gatewayResult.config.bundles).prometheus or null;
    in
    if bundle == null then { } else bundle.resources or { };
  gatewayRoute = gatewayResources."prometheus-remote-write-httproute" or null;

  internalResources =
    let
      bundle = (internalResult.config.bundles).prometheus or null;
    in
    if bundle == null then { } else bundle.resources or { };
  internalRoute = internalResources."prometheus-remote-write-httproute" or null;
in
lib.runTests {
  testOptionsDeclared = {
    expr =
      disabledResult.config.floes.prometheus ? enable
      && disabledResult.config.floes.prometheus ? remoteWrite;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testNamespaceDefault = {
    expr = basicResult.config.floes.prometheus.namespace;
    expected = "prometheus";
  };

  testProvidesRemoteWriteUrl = {
    expr = basicExports.remoteWriteUrl or null;
    expected = "http://prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local:9090/api/v1/write";
  };

  testProvidesUrl = {
    expr = basicExports.url or null;
    expected = "http://prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local:9090";
  };

  testCrdsBundleEmitted = {
    expr = if crdsBundle == null then null else crdsBundle.yamls;
    expected = [ "prometheus-crds-stub" ];
  };

  testKustomizeServicePatchPresent = {
    expr =
      if basicBundle == null then
        false
      else
        let
          patches = basicBundle.helmCharts.prometheus.kustomize.patches or [ ];
        in
        builtins.length patches == 1 && (builtins.head patches).target.kind == "Service";
    expected = true;
  };

  testPromSpecPropagates = {
    expr =
      if basicValues == null then
        null
      else
        {
          retention = basicValues.prometheus.prometheusSpec.retention;
          enableReceiver = basicValues.prometheus.prometheusSpec.enableRemoteWriteReceiver;
        };
    expected = {
      retention = "15d";
      enableReceiver = true;
    };
  };

  testDefaultSubchartToggles = {
    expr =
      if basicValues == null then
        null
      else
        {
          alertmanager = basicValues.alertmanager.enabled;
          bundledGrafana = basicValues.grafana.enabled;
          nodeExporter = basicValues.nodeExporter.enabled;
        };
    expected = {
      alertmanager = true;
      bundledGrafana = false;
      nodeExporter = true;
    };
  };

  testPublicGatewayRoute = {
    expr = gatewayRoute != null && gatewayRoute.kind == "HTTPRoute";
    expected = true;
  };

  testInternalRouteUsesInternalGateway = {
    expr = if internalRoute == null then null else (builtins.head internalRoute.spec.parentRefs).name;
    expected = "stub-internal";
  };

  testInternalHostnameRegistered = {
    expr = internalResult.config.floes.gateway.internalHostnames or [ ];
    expected = [ "prometheus-rw.internal.test" ];
  };
}
