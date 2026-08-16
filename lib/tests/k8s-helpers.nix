{ lib }:

let
  helpers = import ../k8s-helpers.nix { inherit lib; };
  inherit (helpers)
    mkGatewayExposure
    mkGatewayParentFor
    mkGatewayParent
    mkHttpRoute
    mkTlsRoute
    mkCertificate
    ;
in
lib.runTests {
  testGatewayParent = {
    expr = mkGatewayParent {
      name = "default-gateway";
      namespace = "kube-system";
    };
    expected = {
      name = "default-gateway";
      sectionName = "https";
      namespace = "kube-system";
    };
  };

  testGatewayParentOmitsNullNamespace = {
    expr = mkGatewayParent { name = "gw"; };
    expected = {
      name = "gw";
      sectionName = "https";
    };
  };

  testHttpRouteShape = {
    expr = mkHttpRoute {
      name = "grafana";
      namespace = "grafana";
      hostname = "grafana.homelab.test";
      gatewayParent = {
        name = "gw";
        sectionName = "https";
      };
      backend = {
        name = "grafana";
        port = 80;
      };
    };
    expected = {
      apiVersion = "gateway.networking.k8s.io/v1";
      kind = "HTTPRoute";
      metadata = {
        name = "grafana";
        namespace = "grafana";
      };
      spec = {
        parentRefs = [
          {
            name = "gw";
            sectionName = "https";
          }
        ];
        hostnames = [ "grafana.homelab.test" ];
        rules = [
          {
            matches = [
              {
                path = {
                  type = "PathPrefix";
                  value = "/";
                };
              }
            ];
            backendRefs = [
              {
                name = "grafana";
                port = 80;
              }
            ];
          }
        ];
      };
    };
  };

  testHttpRouteWithLabels = {
    expr =
      (mkHttpRoute {
        name = "r";
        namespace = "ns";
        hostname = "h";
        gatewayParent = {
          name = "gw";
          sectionName = "https";
        };
        backend = {
          name = "b";
          port = 8080;
        };
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      }).metadata;
    expected = {
      name = "r";
      namespace = "ns";
      labels."app.kubernetes.io/managed-by" = "catallaxy";
    };
  };

  testTlsRouteShape = {
    expr = mkTlsRoute {
      name = "kanidm";
      namespace = "kanidm";
      hostname = "idm.homelab.test";
      gatewayParent = {
        name = "gw";
        sectionName = "tls";
      };
      backend = {
        name = "kanidm";
        port = 8443;
      };
    };
    expected = {
      apiVersion = "gateway.networking.k8s.io/v1alpha2";
      kind = "TLSRoute";
      metadata = {
        name = "kanidm";
        namespace = "kanidm";
      };
      spec = {
        parentRefs = [
          {
            name = "gw";
            sectionName = "tls";
          }
        ];
        hostnames = [ "idm.homelab.test" ];
        rules = [
          {
            backendRefs = [
              {
                name = "kanidm";
                port = 8443;
              }
            ];
          }
        ];
      };
    };
  };

  testCertificateShape = {
    expr = mkCertificate {
      name = "grafana-tls";
      namespace = "grafana";
      secretName = "grafana-tls";
      issuerRef = {
        name = "lab-ca";
        kind = "ClusterIssuer";
      };
      dnsNames = [ "grafana.homelab.test" ];
    };
    expected = {
      apiVersion = "cert-manager.io/v1";
      kind = "Certificate";
      metadata = {
        name = "grafana-tls";
        namespace = "grafana";
      };
      spec = {
        secretName = "grafana-tls";
        issuerRef = {
          name = "lab-ca";
          kind = "ClusterIssuer";
        };
        dnsNames = [ "grafana.homelab.test" ];
      };
    };
  };

  # Eight floes built this by hand and five of them hand-rolled the whole
  # HTTPRoute alongside it.

  testExposureRendersARouteAndACertificate = {
    expr =
      let
        r = mkGatewayExposure {
          name = "grafana";
          namespace = "monitoring";
          domain = "grafana.lab.test";
          gateway = {
            enable = true;
            tier = "public";
            gatewayRef = "public-gateway";
            gatewayNamespace = "kube-system";
          };
          internalGatewayName = "internal-gateway";
          sectionName = "https";
          backend = {
            name = "grafana";
            port = 80;
          };
          tls = {
            secretName = "grafana-tls";
            issuerRef = {
              name = "lab-ca";
              kind = "ClusterIssuer";
            };
          };
        };
        route = r."grafana-route";
        cert = r."grafana-tls";
      in
      [
        (builtins.attrNames r)
        route.kind
        (builtins.head route.spec.parentRefs)
        route.spec.hostnames
        (builtins.head (builtins.head route.spec.rules).matches).path.value
        cert.kind
        cert.spec.dnsNames
      ];
    expected = [
      [
        "grafana-route"
        "grafana-tls"
      ]
      "HTTPRoute"
      {
        name = "public-gateway";
        namespace = "kube-system";
        sectionName = "https";
      }
      [ "grafana.lab.test" ]
      "/"
      "Certificate"
      [ "grafana.lab.test" ]
    ];
  };

  # The listener is the field the hand-written copies disagreed about: five
  # read the Gateway's exported name and three took a hardcoded "https". A
  # plaintext lab exports "http", so those three named a listener that was not
  # there. It has no default now.
  testExposureTakesTheListenerItIsGiven = {
    expr =
      let
        r = mkGatewayExposure {
          name = "x";
          namespace = "ns";
          domain = "x.lab.test";
          gateway = {
            enable = true;
            tier = "internal";
            gatewayRef = "public-gateway";
            gatewayNamespace = null;
          };
          internalGatewayName = "internal-gateway";
          sectionName = "http";
          backend = {
            name = "x";
            port = 8080;
          };
        };
      in
      builtins.head r."x-route".spec.parentRefs;
    expected = {
      name = "internal-gateway";
      sectionName = "http";
    };
  };

  # A floe with the gateway off renders nothing to attach, but still wants the
  # certificate: it may be reached some other way. Every caller did this.
  testACertificateIsNotGatedOnTheGateway = {
    expr =
      let
        r = mkGatewayExposure {
          name = "x";
          namespace = "ns";
          domain = "x.lab.test";
          gateway = {
            enable = false;
            tier = "public";
            gatewayRef = "g";
            gatewayNamespace = null;
          };
          internalGatewayName = "i";
          sectionName = "https";
          backend = {
            name = "x";
            port = 80;
          };
          tls = {
            secretName = "x-tls";
            issuerRef = {
              name = "lab-ca";
              kind = "ClusterIssuer";
            };
          };
        };
      in
      builtins.attrNames r;
    expected = [ "x-tls" ];
  };

  testAFloeWithNoDomainIsNotExposedAtAll = {
    expr =
      let
        r = mkGatewayExposure {
          name = "x";
          namespace = "ns";
          domain = "";
          gateway = {
            enable = true;
            tier = "public";
            gatewayRef = "g";
            gatewayNamespace = null;
          };
          internalGatewayName = "i";
          sectionName = "https";
          backend = {
            name = "x";
            port = 80;
          };
          tls = {
            secretName = "x-tls";
            issuerRef = {
              name = "lab-ca";
              kind = "ClusterIssuer";
            };
          };
        };
      in
      r;
    expected = { };
  };

  # kanidm publishes a second route on the internal Gateway regardless of its
  # own tier, so the name can be overridden.
  testAParentCanBePinnedToANamedGateway = {
    expr = mkGatewayParentFor {
      gateway = {
        tier = "public";
        gatewayRef = "public-gateway";
        gatewayNamespace = null;
      };
      internalGatewayName = "internal-gateway";
      sectionName = "tls-passthrough";
      name = "internal-gateway";
    };
    expected = {
      name = "internal-gateway";
      sectionName = "tls-passthrough";
    };
  };
}
