{ lib }:

rec {

  scopeAssertion =
    {
      consumer,
      clientId,
      scopes,
      client,
    }:
    let
      grantedScopes = if client == null then [ ] else client.grantedScopes;
    in
    mkScopeAssertion {
      requestedScopes = scopes;
      idpEnabled = client != null;
      consumerName = consumer;
      inherit grantedScopes clientId;
    };

  mkScopeAssertion =
    {
      requestedScopes,
      grantedScopes,
      idpEnabled,
      consumerName,
      clientId,
    }:
    let
      missing = lib.subtractLists grantedScopes requestedScopes;
    in
    {
      assertion = !idpEnabled || missing == [ ];
      message = ''
        ${consumerName}.oidc.scopes requests scopes not granted by the IdP's oauth2Client "${clientId}".
        Missing:   ${lib.concatStringsSep ", " missing}
        Requested: ${lib.concatStringsSep ", " requestedScopes}
        Granted:   ${lib.concatStringsSep ", " grantedScopes}

        Add the missing scopes to every scopeMap (and/or supScopeMap) entry
        for this client on the IdP floe, or trim ${consumerName}.oidc.scopes.
      '';
    };
}
