{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  forgejo = import ../../../modules/lab/cluster/floes/forgejo;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.forgejo = {
        chart = pkgs.emptyDirectory;
      };
      k8sHelpers = {
        mkGatewayParent = args: args;
        mkHttpRoute = args: {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          inherit (args) name namespace;
          spec = args;
        };
        mkCertificate = args: {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          inherit (args) name namespace;
          spec = args;
        };
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
    };

  minimalCfg = {
    enable = true;
    domain = "git.test.local";
    database = {
      host = "pg-rw.forgejo.svc.cluster.local";
      secretRef.name = "pg-app";
    };
  };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = forgejo;
      cluster = {
        imports = [ stubUpstream ];
        floes.forgejo.enable = false;
      };
    }
  );

  publicResult = evalFloe (
    baseArgs
    // {
      floe = forgejo;
      cluster = {
        imports = [ stubUpstream ];
        floes.forgejo = minimalCfg // {
          tls.issuerRef = {
            name = "lab-ca";
            kind = "ClusterIssuer";
          };
        };
      };
    }
  );

  internalResult = evalFloe (
    baseArgs
    // {
      floe = forgejo;
      cluster = {
        imports = [ stubUpstream ];
        floes.forgejo = minimalCfg // {
          gateway.tier = "internal";
        };
      };
    }
  );

  bootstrapResult = evalFloe (
    baseArgs
    // {
      floe = forgejo;
      cluster = {
        imports = [ stubUpstream ];
        floes.forgejo = minimalCfg // {
          bootstrap = {
            enable = true;
            orgs = [ "infrastructure" ];
            repos.manifests = {
              org = "infrastructure";
              description = "argocd manifests";
            };
            deployKeys.argocd = {
              org = "infrastructure";
              repo = "manifests";
              targetSecret = {
                namespace = "argocd";
                name = "argocd-repo-manifests";
              };
            };
          };
        };
      };
    }
  );

  publicBundle = (publicResult.config.bundles).forgejo or null;
  publicResources = if publicBundle == null then { } else publicBundle.resources;
  publicRoute = publicResources.forgejo-route or null;

  internalBundle = (internalResult.config.bundles).forgejo or null;
  internalRoute =
    if internalBundle == null then null else internalBundle.resources.forgejo-route or null;

  bootstrapBundle = (bootstrapResult.config.bundles).forgejo-bootstrap or null;
  bootstrapResources = if bootstrapBundle == null then { } else bootstrapBundle.resources;
in
lib.runTests {
  testOptionsDeclared = {
    expr =
      disabledResult.config.floes.forgejo ? enable
      && disabledResult.config.floes.forgejo ? database
      && disabledResult.config.floes.forgejo ? bootstrap;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testNamespaceDefault = {
    expr = publicResult.config.floes.forgejo.namespace;
    expected = "forgejo";
  };

  testHttpRouteEmitted = {
    expr = publicRoute != null && publicRoute.kind == "HTTPRoute";
    expected = true;
  };

  testTlsCertificateEmitted = {
    expr = publicResources ? "forgejo-tls" && publicResources."forgejo-tls".kind == "Certificate";
    expected = true;
  };

  testInternalRouteUsesInternalGateway = {
    expr = if internalRoute == null then null else internalRoute.spec.gatewayParent.name;
    expected = "stub-internal";
  };

  testInternalHostnameRegistered = {
    expr = internalResult.config.floes.gateway.internalHostnames or [ ];
    expected = [ "git.test.local" ];
  };

  testBootstrapRbacEmitted = {
    expr =
      bootstrapResources ? forgejo-bootstrap-sa
      && bootstrapResources ? forgejo-bootstrap-role
      && bootstrapResources ? forgejo-bootstrap-rb
      && bootstrapResources ? "forgejo-bootstrap-role-argocd"
      && bootstrapResources ? "forgejo-bootstrap-rb-argocd";
    expected = true;
  };

  testBootstrapDisabledByDefault = {
    expr = (publicResult.config.bundles) ? forgejo-bootstrap;
    expected = false;
  };
}
