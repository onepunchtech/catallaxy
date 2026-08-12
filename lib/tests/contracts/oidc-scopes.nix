{ lib, pkgs }:

let
  oidc = (import ../../contracts { inherit lib; }).oidc;
in
lib.runTests {

  testExactMatchPasses = {
    expr =
      (oidc.mkScopeAssertion {
        requestedScopes = [
          "openid"
          "email"
          "groups"
        ];
        grantedScopes = [
          "openid"
          "email"
          "groups"
        ];
        idpEnabled = true;
        consumerName = "harbor";
        clientId = "harbor";
      }).assertion;
    expected = true;
  };

  testSubsetPasses = {
    expr =
      (oidc.mkScopeAssertion {
        requestedScopes = [
          "openid"
          "email"
        ];
        grantedScopes = [
          "openid"
          "email"
          "groups"
          "profile"
        ];
        idpEnabled = true;
        consumerName = "harbor";
        clientId = "harbor";
      }).assertion;
    expected = true;
  };

  testMissingScopesFails = {
    expr =
      (oidc.mkScopeAssertion {
        requestedScopes = [
          "openid"
          "email"
          "profile"
          "groups"
          "offline_access"
        ];
        grantedScopes = [
          "openid"
          "email"
          "groups"
        ];
        idpEnabled = true;
        consumerName = "harbor";
        clientId = "harbor";
      }).assertion;
    expected = false;
  };

  testFailureMessageNamesMissing =
    let
      result = oidc.mkScopeAssertion {
        requestedScopes = [
          "openid"
          "profile"
          "offline_access"
        ];
        grantedScopes = [ "openid" ];
        idpEnabled = true;
        consumerName = "harbor";
        clientId = "harbor";
      };
    in
    {
      expr =
        lib.hasInfix "profile" result.message
        && lib.hasInfix "offline_access" result.message
        && lib.hasInfix "harbor" result.message;
      expected = true;
    };

  testDisabledIdpSkips = {
    expr =
      (oidc.mkScopeAssertion {
        requestedScopes = [
          "openid"
          "offline_access"
        ];
        grantedScopes = [ ];
        idpEnabled = false;
        consumerName = "harbor";
        clientId = "harbor";
      }).assertion;
    expected = true;
  };

  testNullClientPasses = {
    expr =
      (oidc.scopeAssertion {
        consumer = "harbor";
        clientId = "harbor";
        scopes = [
          "openid"
          "offline_access"
        ];
        client = null;
      }).assertion;
    expected = true;
  };

  testNullClientMessageEvaluates = {
    expr =
      let
        result = oidc.scopeAssertion {
          consumer = "harbor";
          clientId = "harbor";
          scopes = [ "openid" ];
          client = null;
        };
      in
      lib.hasInfix "harbor" result.message;
    expected = true;
  };

  testClientGrantsAreRead = {
    expr =
      (oidc.scopeAssertion {
        consumer = "zot";
        clientId = "zot";
        scopes = [
          "openid"
          "groups"
        ];
        client = {
          grantedScopes = [ "openid" ];
        };
      }).assertion;
    expected = false;
  };

  testClientGrantingEverythingPasses = {
    expr =
      (oidc.scopeAssertion {
        consumer = "zot";
        clientId = "zot";
        scopes = [
          "openid"
          "groups"
        ];
        client = {
          grantedScopes = [
            "openid"
            "groups"
            "email"
          ];
        };
      }).assertion;
    expected = true;
  };
}
