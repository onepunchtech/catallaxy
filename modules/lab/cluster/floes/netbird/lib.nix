{ lib, cfg }:
let
  names = import ./names.nix { };
in
rec {
  inherit (names)
    clusterRouterKeyName
    operatorKeyName
    setupKeySecretName
    setupKeySecretKey
    jwtGroupUuidsSecretName
    managedBy
    owner
    ;

  oauthRedirectUrls = map (port: "http://localhost:${toString port}/") cfg.client.callbackPorts;

  signalPort = 80;

  signalLegacyGrpcPort = 10000;

  idpClientId = if cfg.idp.client != null then cfg.idp.client.clientId else "";
  idpIssuer = if cfg.idp.client != null then cfg.idp.client.issuer else "";
  idpJwksUri = if cfg.idp.client != null then cfg.idp.client.jwksUri else "";
  idpAuthorizationEndpoint =
    if cfg.idp.client != null then cfg.idp.client.authorizationEndpoint else "";
  idpBrowserTokenEndpoint = if cfg.idp.client != null then cfg.idp.client.tokenEndpoint else "";
  idpPublicIssuer =
    if cfg.idp.client == null then
      ""
    else if cfg.idp.client.publicIssuer != "" then
      cfg.idp.client.publicIssuer
    else
      cfg.idp.client.issuer;
  idpMachineTokenEndpoint = if cfg.idp.machine != null then cfg.idp.machine.tokenEndpoint else "";
  idpMachineTokenRef = if cfg.idp.machine != null then cfg.idp.machine.tokenRef else null;

  hasClientSecretRef = idpMachineTokenRef != null;

  hasCaBundle = cfg.tls.caBundle != null;

  signalDomain =
    if cfg.signal.domain != "" then
      cfg.signal.domain
    else
      let
        parts = lib.splitString "." cfg.domain;
        head = builtins.head parts;
        tail = builtins.tail parts;
      in
      lib.concatStringsSep "." ([ "${head}-signal" ] ++ tail);

  dashboardDomain =
    if cfg.dashboard.domain != "" then
      cfg.dashboard.domain
    else
      let
        parts = lib.splitString "." cfg.domain;
        parent = lib.concatStringsSep "." (lib.tail parts);
      in
      "nb-dashboard.${parent}";

  mgmtHost = "netbird-management.${cfg.namespace}.svc.cluster.local";

  signalHost = "netbird-signal.${cfg.namespace}.svc.cluster.local";

  mgmtInternalUrl = "http://${mgmtHost}";

  mgmtInternalUrlPort80 = "http://${mgmtHost}:80";

  mgmtExternalUrl = "https://${cfg.domain}";

  apiTokenSecretName = cfg.operator.apiTokenSecretName;

  apiTokenSecretKey = cfg.operator.apiTokenSecretKey;

  adminGroupsJson = builtins.toJSON cfg.operator.adminGroupsFromJwt;

  jwtDiscoverySpns = lib.unique (
    cfg.operator.adminGroupsFromJwt
    ++ cfg.operator.autoGroupsFromJwt
    ++ (cfg.routing.sourceGroups or [ ])
  );

  jwtDiscoverySpnsJson = builtins.toJSON jwtDiscoverySpns;

  defaultSetupKeys = {
    "${clusterRouterKeyName}" = {
      autoGroups = [ "routers" ];
      duration = "8760h";
      ephemeral = false;
    };
    "${operatorKeyName}" = {
      autoGroups = [ "operators" ];
      duration = "8760h";
      ephemeral = false;
    };
  };

  allSetupKeys = defaultSetupKeys // cfg.setupKeys;

  defaultGroups = {
    routers.specName = "routers";
    operators.specName = "operators";
  };

  spnSlug = spn: lib.replaceStrings [ "@" "." "_" ] [ "-at-" "-" "-" ] (lib.toLower spn);

  autoGroupCrDefs =
    let
      existingNames = (lib.attrNames defaultGroups) ++ (lib.attrNames cfg.groups);
    in
    lib.listToAttrs (
      lib.concatMap (
        spn:
        let
          n = spnSlug spn;
        in
        if lib.elem n existingNames then
          [ ]
        else
          [
            {
              name = n;
              value = {
                specName = spn;
              };
            }
          ]
      ) cfg.operator.autoGroupsFromJwt
    );

  allGroups =
    defaultGroups // (lib.mapAttrs (name: _: { specName = name; }) cfg.groups) // autoGroupCrDefs;

  waitTimeoutSeconds = cfg.wait.attempts * cfg.wait.intervalSeconds;

  waitTimeoutStr = "${toString waitTimeoutSeconds}s";
}
