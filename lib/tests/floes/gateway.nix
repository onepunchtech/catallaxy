{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  gateway = import ../../../modules/lab/cluster/floes/gateway;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.traefik = {
        chart = pkgs.emptyDirectory;
      };
      k8sSpecs = {
        standaloneCrds.gateway-api = "gateway-api-crds-stub";
      };
    };
  };

  stubCluster =
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

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = gateway;
      cluster = {
        imports = [ stubCluster ];
        floes.gateway.enable = false;
      };
    }
  );

  basicResult = evalFloe (
    baseArgs
    // {
      floe = gateway;
      cluster = {
        imports = [ stubCluster ];
        floes.gateway.enable = true;
      };
    }
  );

  tlsResult = evalFloe (
    baseArgs
    // {
      floe = gateway;
      cluster = {
        imports = [ stubCluster ];
        floes.gateway = {
          enable = true;
          tls = {
            enable = true;
            domain = "test.local";
          };
        };
      };
    }
  );

  internalNetbirdResult = evalFloe (
    baseArgs
    // {
      floe = gateway;
      cluster = {
        imports = [ stubCluster ];
        floes.gateway = {
          enable = true;
          internal = {
            enable = true;
            exposureMode = "netbird";
            clusterIPAddress = "10.96.0.250";
            domain = "internal.test.local";
          };
          tls = {
            enable = true;
            domain = "test.local";
            issuerRef = {
              name = "lab-ca";
              kind = "ClusterIssuer";
            };
          };
        };
      };
    }
  );

  invalidNetbirdResult = evalFloe (
    baseArgs
    // {
      floe = gateway;
      cluster = {
        imports = [ stubCluster ];
        floes.gateway = {
          enable = true;
          internal = {
            enable = true;
            exposureMode = "netbird";
          };
        };
      };
    }
  );

  wrongCidrResult = evalFloe (
    baseArgs
    // {
      floe = gateway;
      cluster = {
        imports = [ stubCluster ];
        floes.gateway = {
          enable = true;
          internal = {
            enable = true;
            exposureMode = "netbird";
            clusterIPAddress = "172.16.5.250";
          };
        };
      };
    }
  );

  basicGateway = (basicResult.config.bundles).gateway or null;
  basicResources = if basicGateway == null then { } else basicGateway.resources;

  tlsGateway = (tlsResult.config.bundles).gateway or null;
  tlsListeners =
    if tlsGateway == null then [ ] else tlsGateway.resources."default-gateway".spec.listeners;
  tlsBundle = (tlsResult.config.bundles).gateway-tls or null;
  tlsBundleResources = if tlsBundle == null then { } else tlsBundle.resources;

  internalGateway = (internalNetbirdResult.config.bundles).gateway or null;
  internalResources = if internalGateway == null then { } else internalGateway.resources;

  crdsBundle = (basicResult.config.bundles).gateway-api-crds or null;

  exports = basicResult.config.floes.gateway.exports or { };
  tlsExports = tlsResult.config.floes.gateway.exports or { };
  internalExports = internalNetbirdResult.config.floes.gateway.exports or { };

  hostnamesResult = evalFloe (
    baseArgs
    // {
      floe = gateway;
      cluster = {
        imports = [
          stubCluster
          { floes.gateway.internalHostnames = [ "svc-a.internal.test" ]; }
          { floes.gateway.internalHostnames = [ "svc-b.internal.test" ]; }
        ];
        floes.gateway.enable = true;
      };
    }
  );

  failing = res: builtins.filter (a: !a.assertion) res.config.assertions;
in
lib.runTests {
  testOptionsDeclared = {
    expr =
      disabledResult.config.floes.gateway ? enable && disabledResult.config.floes.gateway ? internal;
    expected = true;
  };

  testProvidesDefaultsOnDisabled = {
    expr = disabledResult.config.floes.gateway.exports.internalGatewayName;
    expected = "default-gateway";
  };

  testNamespaceDefaultPreserved = {
    expr = basicResult.config.floes.gateway.namespace;
    expected = "kube-system";
  };

  testInternalNameFallback = {
    expr = exports.internalGatewayName or null;
    expected = "default-gateway";
  };

  testInternalNamePresent = {
    expr = internalExports.internalGatewayName or null;
    expected = "internal-gateway";
  };

  testCrdsBundleEmitted = {
    expr = if crdsBundle == null then null else crdsBundle.yamls;
    expected = [ "gateway-api-crds-stub" ];
  };

  testPublicGatewayEmitted = {
    expr =
      let
        g = basicResources."default-gateway" or null;
      in
      if g == null then null else g.metadata.labels."catallaxy.io/network-tier";
    expected = "public";
  };

  testTlsListenerEmitted = {
    expr =
      let
        httpsListener = builtins.head (builtins.filter (l: l.name == "https") tlsListeners);
      in
      map (ref: ref.name) httpsListener.tls.certificateRefs;
    expected = [ "gateway-tls" ];
  };

  testTlsBundleCertAndRedirect = {
    expr = tlsBundleResources ? "gateway-tls-cert" && tlsBundleResources ? "http-to-https-redirect";
    expected = true;
  };

  testInternalServiceEmitted = {
    expr =
      let
        s = internalResources."traefik-internal" or null;
      in
      if s == null then null else s.spec.clusterIP;
    expected = "10.96.0.250";
  };

  testNetbirdRequiresClusterIP = {
    expr =
      let
        f = failing invalidNetbirdResult;
      in
      builtins.length f == 1 && lib.hasInfix "clusterIPAddress" (builtins.head f).message;
    expected = true;
  };

  testClusterIpInSubnet = {
    expr =
      let
        f = failing wrongCidrResult;
      in
      builtins.length f == 1 && lib.hasInfix "not inside" (builtins.head f).message;
    expected = true;
  };

  testInternalHostnamesMerge = {
    expr = hostnamesResult.config.floes.gateway.exports.internalHostnames;
    expected = [
      "svc-a.internal.test"
      "svc-b.internal.test"
    ];
  };

  testInternalDomainIsPublishedForConsumers = {
    expr = internalExports.internalDomain or null;
    expected = "internal.test.local";
  };

  testNoInternalTierPublishesNoDomain = {
    expr = disabledResult.config.floes.gateway.exports.internalDomain;
    expected = "";
  };

  testCertificateCoversTheInternalTier = {
    expr =
      let
        certs = lib.filter (r: r.kind or "" == "Certificate") (
          builtins.attrValues (internalNetbirdResult.config.bundles.gateway-tls.resources or { })
        );
      in
      (builtins.head certs).spec.dnsNames;
    expected = [
      "test.local"
      "*.test.local"
      "internal.test.local"
      "*.internal.test.local"
    ];
  };
}
