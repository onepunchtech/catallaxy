{ lib }:

let
  helpers = import ../k8s-helpers.nix { inherit lib; };
  inherit (helpers)
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
}
