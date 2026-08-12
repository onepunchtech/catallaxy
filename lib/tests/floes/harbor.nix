{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  harbor = import ../../../modules/lab/cluster/floes/harbor;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.harbor = {
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
      options.floes.gateway.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      options.floes.cert-manager.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };

  client = grantedScopes: {
    clientId = "harbor";
    issuer = "https://idm.test.local/oauth2/openid/grafana";
    clientSecretRef = {
      name = "harbor-kanidm-oauth2-credentials";
      namespace = "kanidm";
      key = "CLIENT_SECRET";
    };
    inherit grantedScopes;
  };

  mk =
    {
      providers ? { },
      oidc,
    }:
    evalFloe (
      baseArgs
      // {
        inherit providers;
        floe = harbor;
        cluster = {
          imports = [ stubUpstream ];
          floes.harbor = {
            enable = true;
            domain = "registry.test.local";
            inherit oidc;
          };
        };
      }
    );

  failures = r: map (a: a.message) (builtins.filter (a: !a.assertion) r.config.assertions);

  underGranted = mk {
    providers.kanidm.oauth2Clients.harbor = client [ "openid" ];
    oidc = {
      enable = true;
      scopes = [
        "openid"
        "groups"
      ];
    };
  };

  fullyGranted = mk {
    providers.kanidm.oauth2Clients.harbor = client [
      "openid"
      "groups"
    ];
    oidc = {
      enable = true;
      scopes = [
        "openid"
        "groups"
      ];
    };
  };

  noProvider = mk {
    oidc = {
      enable = true;
      scopes = [
        "openid"
        "groups"
      ];
    };
  };

  oidcOff = mk {
    providers.kanidm.oauth2Clients.harbor = client [ ];
    oidc.enable = false;
  };
in
lib.runTests {

  testUnderGrantedScopesFail = {
    expr = builtins.length (failures underGranted);
    expected = 1;
  };

  testFailureNamesTheMissingScope = {
    expr = lib.hasInfix "groups" (builtins.head (failures underGranted));
    expected = true;
  };

  testFullyGrantedPasses = {
    expr = failures fullyGranted;
    expected = [ ];
  };

  testNoProviderFailsWithAClearMessage = {
    expr = failures noProvider;
    expected = [
      "harbor OIDC login is enabled but no identity provider publishes an OAuth2 client named \"harbor\"."
    ];
  };

  testNoProviderLeavesClientNull = {
    expr = noProvider.config.floes.harbor.oidc.client;
    expected = null;
  };

  testDisabledOidcEmitsNoScopeAssertion = {
    expr = builtins.any (a: lib.hasInfix "oidc.scopes" a.message) oidcOff.config.assertions;
    expected = false;
  };

  testClientResolvesFromProvider = {
    expr = fullyGranted.config.floes.harbor.oidc.client.clientSecretRef.name;
    expected = "harbor-kanidm-oauth2-credentials";
  };
}
