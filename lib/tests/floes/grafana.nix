{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  grafana = import ../../../modules/lab/cluster/floes/grafana;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.grafana = {
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
      options.floes.reloader.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };

  client = grantedScopes: {
    clientId = "grafana";
    issuer = "https://idm.test.local/oauth2/openid/grafana";
    clientSecretRef = {
      name = "grafana-kanidm-oauth2-credentials";
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
        floe = grafana;
        cluster = {
          imports = [ stubUpstream ];
          floes.grafana = {
            enable = true;
            domain = "grafana.test.local";
            inherit oidc;
          };
        };
      }
    );

  failures = r: map (a: a.message) (builtins.filter (a: !a.assertion) r.config.assertions);

  underGranted = mk {
    providers.kanidm.oauth2Clients.grafana = client [ "openid" ];
    oidc = {
      enable = true;
      scopes = [
        "openid"
        "groups"
      ];
    };
  };

  fullyGranted = mk {
    providers.kanidm.oauth2Clients.grafana = client [
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
    providers.kanidm.oauth2Clients.grafana = client [ ];
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

  testNoProviderStillEvaluates = {
    expr = failures noProvider;
    expected = [ ];
  };

  testNoProviderLeavesClientNull = {
    expr = noProvider.config.floes.grafana.oidc.client;
    expected = null;
  };

  testDisabledOidcEmitsNoScopeAssertion = {
    expr = builtins.any (a: lib.hasInfix "oidc.scopes" a.message) oidcOff.config.assertions;
    expected = false;
  };

  testClientResolvesFromProvider = {
    expr = fullyGranted.config.floes.grafana.oidc.client.clientSecretRef.name;
    expected = "grafana-kanidm-oauth2-credentials";
  };
}
