{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  zot = import ../../../modules/lab/cluster/floes/zot;

  baseArgs = {
    args = {
      inherit pkgs;
      cataCharts.zot = {
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
      options.floes.gateway.capabilities = lib.mkOption {
        type = lib.types.attrs;
        default = { };
      };
      config.floes.gateway.exports.routing = {
        publicReady = "gateway/public/ready";
      };

      # The payload is what a consumer reads, not the stub's exports. Leaving
      # it empty is a gateway that claims the job and offers nothing for it,
      # which is the case this whole contract exists to stop passing.
      config.floes.gateway.capabilities.provides.api-gateway = {
        routing = {
          publicReady = "gateway/public/ready";
        };
      };
    };

  client = grantedScopes: {
    clientId = "zot";
    issuer = "https://idm.test.local/oauth2/openid/grafana";
    clientSecretRef = {
      name = "zot-kanidm-oauth2-credentials";
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
        floe = zot;
        cluster = {
          imports = [ stubUpstream ];
          floes.zot = {
            enable = true;
            domain = "zot.test.local";
            inherit oidc;
          };
        };
      }
    );

  failures = r: map (a: a.message) (builtins.filter (a: !a.assertion) r.config.assertions);

  underGranted = mk {
    providers.kanidm.oauth2Clients.zot = client [ "openid" ];
    oidc = {
      enable = true;
      scopes = [
        "openid"
        "groups"
      ];
    };
  };

  fullyGranted = mk {
    providers.kanidm.oauth2Clients.zot = client [
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
    providers.kanidm.oauth2Clients.zot = client [ ];
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
      "zot OIDC login is enabled but no identity provider publishes an OAuth2 client named \"zot\"."
    ];
  };

  testNoProviderLeavesClientNull = {
    expr = noProvider.config.floes.zot.oidc.client;
    expected = null;
  };

  testDisabledOidcEmitsNoScopeAssertion = {
    expr = builtins.any (a: lib.hasInfix "oidc.scopes" a.message) oidcOff.config.assertions;
    expected = false;
  };

  testClientResolvesFromProvider = {
    expr = fullyGranted.config.floes.zot.oidc.client.clientSecretRef.name;
    expected = "zot-kanidm-oauth2-credentials";
  };
}
