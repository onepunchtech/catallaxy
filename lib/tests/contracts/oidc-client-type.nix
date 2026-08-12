{ lib, pkgs }:

let
  contracts = import ../../contracts { inherit lib; };

  kanidmShapedValue = {
    clientId = "harbor";
    issuer = "https://idm.example.test/oauth2/openid/harbor";
    internalIssuer = "http://kanidm.kanidm.svc:8443/oauth2/openid/harbor";
    internalJwksUri = "http://kanidm.kanidm.svc:8443/oauth2/openid/harbor/public_key.jwk";
    clientSecretRef = {
      name = "harbor-kanidm-oauth2-credentials";
      namespace = "kanidm";
      key = "CLIENT_SECRET";
    };
    readyProbe = {
      kind = "secret";
      name = "harbor-kanidm-oauth2-credentials";
    };
    grantedScopes = [
      "openid"
      "email"
      "groups"
    ];
    claimValues = {
      groups = [
        "harbor-admins"
        "harbor-users"
      ];
    };
    scopeMapGroups = [
      "harbor-admins"
      "harbor-users"
    ];
  };

  evaluated =
    (lib.evalModules {
      modules = [
        {
          options.client = lib.mkOption { type = contracts.oidc.nullableClient; };
          config.client = kanidmShapedValue;
        }
      ];
    }).config.client;

  evaluatedClients =
    (lib.evalModules {
      modules = [
        {
          options.clients = lib.mkOption { type = contracts.oidc.clientsType; };
          config.clients.harbor = kanidmShapedValue;
        }
      ];
    }).config.clients;
in
lib.runTests {

  testEveryFieldRoundTrips = {
    expr = evaluated;
    expected = kanidmShapedValue;
  };

  testAttrsOfFormRoundTrips = {
    expr = evaluatedClients.harbor;
    expected = kanidmShapedValue;
  };

  testNullIsAccepted = {
    expr =
      (lib.evalModules {
        modules = [
          {
            options.client = lib.mkOption { type = contracts.oidc.nullableClient; };
            config.client = null;
          }
        ];
      }).config.client;
    expected = null;
  };

  testEmptyClientTakesDefaults = {
    expr =
      (lib.evalModules {
        modules = [
          {
            options.clients = lib.mkOption { type = contracts.oidc.clientsType; };
            config.clients.bare = { };
          }
        ];
      }).config.clients.bare;
    expected = {
      clientId = "";
      issuer = "";
      internalIssuer = "";
      internalJwksUri = "";
      clientSecretRef = null;
      readyProbe = { };
      grantedScopes = [ ];
      claimValues = { };
      scopeMapGroups = [ ];
    };
  };

  testSecretRefKeyDefaults = {
    expr =
      (lib.evalModules {
        modules = [
          {
            options.clients = lib.mkOption { type = contracts.oidc.clientsType; };
            config.clients.bare.clientSecretRef.name = "s";
          }
        ];
      }).config.clients.bare.clientSecretRef;
    expected = {
      name = "s";
      namespace = "";
      key = "CLIENT_SECRET";
    };
  };
}
