{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;

  disabled =
    args: floe: cluster:
    (evalFloe (args // { inherit floe cluster; })).config;

  certManagerFloe = import ../../../modules/lab/cluster/floes/cert-manager;
  certManagerArgs = {
    args = {
      inherit pkgs;
      cataCharts.cert-manager = {
        chart = pkgs.emptyDirectory;
        crds = "cert-manager-crds-stub";
      };
    };
  };
  certManagerStub =
    { lib, ... }:
    {
      options.floes.trust-manager.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
  certManagerCfg = disabled certManagerArgs certManagerFloe {
    imports = [ certManagerStub ];
    floes.cert-manager.enable = false;
  };

  gatewayFloe = import ../../../modules/lab/cluster/floes/gateway;
  gatewayArgs = {
    args = {
      inherit pkgs;
      cataCharts.traefik = {
        chart = pkgs.emptyDirectory;
      };
      k8sSpecs.standaloneCrds.gateway-api = "gateway-api-crds-stub";
    };
  };
  gatewayStub =
    { lib, ... }:
    {
      options.cluster.network.serviceSubnet = lib.mkOption {
        type = lib.types.str;
        default = "10.96.0.0/12";
      };

      options.cluster.provisionerOut.publishesGatewayPorts = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      options.cluster.ingress.httpPort = lib.mkOption {
        type = lib.types.port;
        default = 80;
      };
      options.cluster.ingress.httpsPort = lib.mkOption {
        type = lib.types.port;
        default = 443;
      };
      options.cluster.ingress.passthroughPort = lib.mkOption {
        type = lib.types.port;
        default = 8444;
      };

    };
  gatewayCfg = disabled gatewayArgs gatewayFloe {
    imports = [ gatewayStub ];
    floes.gateway.enable = false;
  };

  simpleCharts = name: {
    args = {
      inherit pkgs;
      "cataCharts" = {
        "${name}" = {
          chart = pkgs.emptyDirectory;
        }
        // (if name == "prometheus" then { crds = "prom-crds-stub"; } else { });
      };
    };
  };

  lokiCfg = disabled (simpleCharts "loki") (import ../../../modules/lab/cluster/floes/loki) {
    floes.loki.enable = false;
  };
  prometheusCfg =
    disabled (simpleCharts "prometheus") (import ../../../modules/lab/cluster/floes/prometheus)
      {
        imports = [
          (
            { lib, ... }:
            {
              options.floes.gateway.enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };

              options.floes.gateway.internalHostnames = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
              };
            }
          )
        ];
        floes.prometheus.enable = false;
      };
  tempoCfg = disabled (simpleCharts "tempo") (import ../../../modules/lab/cluster/floes/tempo) {
    floes.tempo.enable = false;
  };
in
lib.runTests {

  testCertManagerNamespace = {
    expr = certManagerCfg.floes.cert-manager.exports.namespace;
    expected = "cert-manager";
  };
  testCertManagerDefaultIssuerRef = {
    expr = certManagerCfg.floes.cert-manager.exports.defaultIssuerRef;
    expected = { };
  };
  testCertManagerCaBundle = {
    expr = certManagerCfg.floes.cert-manager.exports.caBundle;
    expected = null;
  };

  testCertManagerIssuance = {
    expr = certManagerCfg.floes.cert-manager.exports.issuance;
    expected = null;
  };
  testCertManagerCaBundleNamespaceLabel = {
    expr = certManagerCfg.floes.cert-manager.exports.caBundleNamespaceLabel;
    expected = {
      "catallaxy.io/trust-bundle" = "true";
    };
  };

  testGatewayInternalGatewayName = {
    expr = gatewayCfg.floes.gateway.exports.internalGatewayName;
    expected = "default-gateway";
  };
  testGatewayClassName = {
    expr = gatewayCfg.floes.gateway.exports.className;
    expected = "traefik";
  };
  testGatewayNamespace = {
    expr = gatewayCfg.floes.gateway.exports.namespace;
    expected = "kube-system";
  };
  testGatewayInternalEnabled = {
    expr = gatewayCfg.floes.gateway.exports.internalEnabled;
    expected = false;
  };

  testLokiUrl = {
    expr = lokiCfg.floes.loki.exports.url;
    expected = "http://loki.loki.svc.cluster.local:3100";
  };
  testLokiOtlpUrl = {
    expr = lokiCfg.floes.loki.exports.otlpUrl;
    expected = "http://loki.loki.svc.cluster.local:3100/otlp";
  };
  testLokiPort = {
    expr = lokiCfg.floes.loki.exports.port;
    expected = 3100;
  };

  testPrometheusRemoteWriteUrl = {
    expr = prometheusCfg.floes.prometheus.exports.remoteWriteUrl;
    expected = "http://prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local:9090/api/v1/write";
  };
  testPrometheusPort = {
    expr = prometheusCfg.floes.prometheus.exports.port;
    expected = 9090;
  };

  testTempoOtlpGrpc = {
    expr = tempoCfg.floes.tempo.exports.otlpGrpc;
    expected = "tempo.tempo.svc.cluster.local:4317";
  };
  testTempoOtlpHttp = {
    expr = tempoCfg.floes.tempo.exports.otlpHttp;
    expected = "http://tempo.tempo.svc.cluster.local:4318";
  };
  testTempoQueryUrl = {
    expr = tempoCfg.floes.tempo.exports.queryUrl;
    expected = "http://tempo.tempo.svc.cluster.local:3100";
  };
}
