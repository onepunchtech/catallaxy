{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  argocd = import ../../../modules/lab/cluster/floes/argocd;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.argocd = {
        chart = pkgs.emptyDirectory;
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

      options.floes.cert-manager.exports = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      config.floes.cert-manager.exports = {
        caBundle = null;
        issuance = null;
      };
      options.floes.kanidm.exports = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      config.floes.kanidm.exports.identity = null;
    };

  disabledResult = evalFloe (
    baseArgs
    // {
      floe = argocd;
      cluster = {
        imports = [ stubUpstream ];
        floes.argocd.enable = false;
      };
    }
  );

  basicResult = evalFloe (
    baseArgs
    // {
      floe = argocd;
      cluster = {
        imports = [ stubUpstream ];
        floes.argocd.enable = true;
      };
    }
  );

  fullResult = evalFloe (
    baseArgs
    // {
      floe = argocd;
      cluster = {
        imports = [ stubUpstream ];
        floes.argocd = {
          enable = true;
          ha = true;
          domain = "argocd.test.local";
          tls.issuerRef = {
            name = "lab-ca";
            kind = "ClusterIssuer";
          };
          oidc = {
            enable = true;
            issuerUrl = "https://idm.test.local/oauth2/openid/argocd";
            clientId = "argocd";
          };
          rbac.groupBindings.admins = "role:admin";
          repositories.manifests = {
            url = "https://git.test.local/infra.git";
            passwordSecretRef.name = "git-token";
          };
        };
      };
    }
  );

  internalResult = evalFloe (
    baseArgs
    // {
      floe = argocd;
      cluster = {
        imports = [ stubUpstream ];
        floes.argocd = {
          enable = true;
          domain = "argocd.internal.test";
          gateway.tier = "internal";
        };
      };
    }
  );

  basicBundle = (basicResult.config.bundles).argocd or null;
  fullBundle = (fullResult.config.bundles).argocd or null;
  internalBundle = (internalResult.config.bundles).argocd or null;

  fullValues = if fullBundle == null then null else fullBundle.helmCharts.argocd.values;
  fullResources = if fullBundle == null then { } else fullBundle.resources;
  internalHttpRoute =
    if internalBundle == null then null else internalBundle.resources.argocd-httproute or null;
in
lib.runTests {
  testOptionsDeclared = {
    expr =
      disabledResult.config.floes.argocd ? enable && disabledResult.config.floes.argocd ? repositories;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testBasicBundleEmitted = {
    expr = basicBundle != null && basicBundle.helmCharts.argocd.releaseName == "argocd";
    expected = true;
  };

  testNamespaceDefault = {
    expr = basicResult.config.floes.argocd.namespace;
    expected = "argocd";
  };

  testHaTogglesReplicasAndArgs = {
    expr =
      if fullValues == null then
        null
      else
        {
          controller = fullValues.controller.replicas;
          repoServer = fullValues.repoServer.replicas;
          applicationSet = fullValues.applicationSet.replicas;
          serverArgs = fullValues.server.extraArgs;
        };
    expected = {
      controller = 2;
      repoServer = 2;
      applicationSet = 2;
      serverArgs = [ ];
    };
  };

  testOidcConfigRendered = {
    expr =
      if fullValues == null then
        false
      else
        fullValues.configs.cm ? "dex.config" && lib.hasInfix "argocd" fullValues.configs.cm."dex.config";
    expected = true;
  };

  testRbacBindingRendered = {
    expr = if fullValues == null then null else fullValues.configs.rbac."policy.csv";
    expected = "g, admins, role:admin";
  };

  testCertificateEmitted = {
    expr = fullResources ? "argocd-tls" && fullResources."argocd-tls".kind == "Certificate";
    expected = true;
  };

  testRepoSecretLabeled = {
    expr =
      let
        sec = fullResources."argocd-repo-manifests" or null;
      in
      if sec == null then null else sec.metadata.labels."argocd.argoproj.io/secret-type";
    expected = "repository";
  };

  testInternalHttpRouteUsesInternalGateway = {
    expr =
      if internalHttpRoute == null then null else (builtins.head internalHttpRoute.spec.parentRefs).name;
    expected = "stub-internal";
  };

  testInternalHostnameRegistered = {
    expr = internalResult.config.floes.gateway.internalHostnames or [ ];
    expected = [ "argocd.internal.test" ];
  };
}
