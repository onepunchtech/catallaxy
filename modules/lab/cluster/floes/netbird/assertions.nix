{
  lib,
  cfg,
  nb,
  peerEnabled,
}:
let
  inherit (nb)
    idpJwksUri
    idpAuthorizationEndpoint
    idpBrowserTokenEndpoint
    ;

  isFqdn =
    s: builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+" s != null;

  controlPlaneRequires =
    map
      (req: {
        assertion = !cfg.management.enable || peerEnabled req;
        message = ''
          netbird: `management.enable = true` requires floe '${req}' to be enabled.
            The control plane serves an HTTPRoute with a cert-manager
            Certificate and authenticates against kanidm via kaniop.
            Either enable '${req}' on this cluster, or set
            `floes.netbird.management.enable = false` for a peer-only
            cluster that just joins an existing mesh.
        '';
      })
      [
        "gateway"
        "kanidm"
        "kaniop"
        "cert-manager"
      ];

  clientVersion = cfg.client.package.version or null;
  serverTag = lib.last (lib.splitString ":" cfg.images.management.ref);
  majorMinor = v: lib.concatStringsSep "." (lib.take 2 (lib.splitString "." v));

  serverTagComparable = builtins.match "v?[0-9]+\\.[0-9]+\\..*" serverTag != null;

  netbirdAssertions = controlPlaneRequires ++ [
    {
      assertion =
        !cfg.versionCheck
        || clientVersion == null
        || !serverTagComparable
        || majorMinor (lib.removePrefix "v" serverTag) == majorMinor clientVersion;
      message = ''
        netbird: the host client and the management server disagree on version.
          client  ${toString clientVersion}   (floes.netbird.client.package)
          server  ${cfg.images.management.ref}
        A client a minor version away from its management server hangs
        during registration with no error, so this is a hard stop at eval
        rather than a silent stall during `cata lab up`.
        Set ONE of:
          floes.netbird.client.package  : the binary this lab runs on the host
          floes.netbird.version         : the tag all four server images derive from
        Or set `floes.netbird.versionCheck = false` to run a skewed pair deliberately.
      '';
    }
    {
      assertion = idpJwksUri == "" || (idpAuthorizationEndpoint != "" && idpBrowserTokenEndpoint != "");
      message = ''
        netbird: `idp.client.jwksUri` is set, which turns off OIDC discovery,
        but `authorizationEndpoint` / `tokenEndpoint` are empty.

        Discovery is what used to supply the PKCE endpoints, so without
        them `netbird up` has no URL to open and waits for a browser
        callback that can never arrive. Wire all three from the provider:

          jwksUri               = ...exports.oauth2Clients.<id>.internalJwksUri;
          authorizationEndpoint = ...exports.authorizationEndpoint;
          tokenEndpoint         = ...exports.tokenEndpoint;
      '';
    }
    {
      assertion = !cfg.operator.enable || cfg.operator.chart != null;
      message = ''
        netbird: `operator.enable = true` but `operator.chart` is null.
          Either provide the chart (`cataCharts.netbird-operator` must be present),
          or set `floes.netbird.operator.enable = false` to skip the operator.
      '';
    }
    {
      assertion = !cfg.routing.enable || cfg.operator.enable;
      message = ''
        netbird: `routing.enable = true` requires `operator.enable = true`.
          Routing provisions Netbird Network / Router / Policy / DNS resources
          via the operator's REST API, so the operator must be running for the
          routing Job to succeed.
      '';
    }
    {
      assertion = !cfg.agent.enable || cfg.agent.setupKeyRef.name != "";
      message = ''
        netbird: `agent.enable = true` but `agent.setupKeyRef.name` is empty.
          The agent DaemonSet polls this Secret for its setup-key at Pod startup.
          Default is `setup-key-cluster-router` (minted by the operator when
          `setupKeys.cluster-router` is declared).
      '';
    }
    {
      assertion = !cfg.agent.enable || cfg.agent.managementUrl != "";
      message = ''
        netbird: `agent.enable = true` but `agent.managementUrl` is empty.
          Set to the netbird management HTTPS URL the agent should register with.
          For an in-lab agent, this is typically `https://${cfg.domain}`.
      '';
    }
    {
      assertion =
        !(cfg.agent.enable && lib.hasPrefix "https://" cfg.agent.managementUrl) || cfg.tls.caBundle != null;
      message = ''
        netbird: `agent.enable = true` with an https `managementUrl` but
        `tls.caBundle` is null, so the agent Pod has no CA to verify it with.

          The lab CA signs that endpoint, and it reaches Pods only through
          trust-manager's bundle; cert-manager emits `lab-ca-bundle` only when
          `floes.trust-manager.enable = true` in THIS cluster. Without it the
          agent fails TLS with `certificate verify failed`, never registers,
          and the mesh silently has no router peer (mesh.local, 2026-08-04).

          Enable `floes.trust-manager.enable = true` here, or set
          `tls.caBundle` explicitly if the endpoint is signed by a CA the
          Pod's image already trusts.
      '';
    }
    {
      assertion = !(cfg.management.enable && cfg.gateway.enable) || cfg.tls.issuerRef != null;
      message = ''
        netbird: `gateway.enable = true` but `tls.issuerRef` is null.
          With the gateway enabled, netbird emits HTTPRoute + Certificate resources
          and cert-manager mints TLS. Either set `tls.issuerRef = { name = "<clusterissuer>"; }`,
          or set `gateway.enable = false` to skip host-side routing.
      '';
    }
    {
      assertion = cfg.domain != "" && isFqdn cfg.domain;
      message = ''
        netbird: `domain` (${cfg.domain}) is not a valid FQDN.
          Set `floes.netbird.domain` to the public hostname the management
          server serves on, e.g. "vpn.example.com".
      '';
    }

    (
      let

        nbClient = cfg.dashboard.oidc.client;
        kanidmAvailable = nbClient != null;
        usingClaimMap = cfg.operator.jwtGroupsClaimName != "groups";
        claimMapValues =
          if nbClient == null then [ ] else nbClient.claimValues.${cfg.operator.jwtGroupsClaimName} or [ ];
        missingClaimValues = lib.filter (g: !(lib.elem g claimMapValues)) cfg.operator.autoGroupsFromJwt;

        scopeMapGroups = if nbClient == null then [ ] else nbClient.scopeMapGroups;
        stripDomain = spn: lib.head (lib.splitString "@" spn);
        baseGroups = map stripDomain cfg.operator.autoGroupsFromJwt;
        overlap = lib.filter (g: lib.elem g scopeMapGroups) baseGroups;
        singleCandidateOverlap = lib.length baseGroups == 1 && overlap == baseGroups;
      in
      if usingClaimMap then

        {
          assertion =
            !(kanidmAvailable && cfg.operator.enable && nbClient != null) || missingClaimValues == [ ];
          message = ''
            netbird: `operator.autoGroupsFromJwt` references values not emitted by any
            `claimMap` entry named "${cfg.operator.jwtGroupsClaimName}" on the netbird
            OAuth2 client: ${lib.concatStringsSep ", " missingClaimValues}.

            With `jwtGroupsClaimName = "${cfg.operator.jwtGroupsClaimName}"`, netbird reads
            the named claim (populated by kanidm's claimMap). Every value in
            autoGroupsFromJwt MUST be a literal that claimMap emits for at least one
            user's group membership. Otherwise the peer joins the mesh assigned to
            nothing and the routing Policy never grants it access.

            Fix: add each missing value to the netbird OAuth2 client's claimMap in
            aspects/identity.nix, e.g.:
              claimMap = [{
                name = "${cfg.operator.jwtGroupsClaimName}";
                joinStrategy = "array";
                valuesMap = [{ group = "<kanidm-group>"; values = [ "<missing-value>" ]; }];
              }];
          '';
        }
      else

        {
          assertion = !(kanidmAvailable && cfg.operator.enable) || !singleCandidateOverlap;
          message = ''
            netbird: `operator.autoGroupsFromJwt` is a single SPN whose base group is
            in the kanidm netbird OAuth2 client's scopeMap: ${lib.concatStringsSep ", " overlap}.

            Kanidm non-deterministically returns scopeMap-referenced groups as UUIDs
            (not SPNs) in the JWT `groups` claim. With only one candidate SPN, the
            first drop leaves the peer in zero groups the routing Policy references
            Mesh joins but no routes, no DNS, service access 502s at Traefik.

            RECOMMENDED FIX: switch to the deterministic `claimMap` pattern,
            set `floes.netbird.operator.jwtGroupsClaimName = "mesh_roles"` and
            add a `claimMap` on the netbird kanidm OAuth2 client that projects
            mesh-role group memberships into that claim with literal values.
            See [[reference-kanidm-groups-claim-scopemap-quirk]].

            Interim fix: list at least two candidate SPNs (each in the client's
            scopeMap) so at least one always survives.
          '';
        }
    )

    (
      let
        missing = lib.filter (
          g: !(lib.elem g cfg.operator.autoGroupsFromJwt)
        ) cfg.operator.adminGroupsFromJwt;
      in
      {
        assertion = missing == [ ];
        message = ''
          netbird: `operator.adminGroupsFromJwt` references SPN(s) not in
          `operator.autoGroupsFromJwt`: ${lib.concatStringsSep ", " missing}.

          A user's Netbird `auto_groups` field is populated from the JWT
          `groups` claim filtered against autoGroupsFromJwt. The admin
          reconciler matches on auto_groups, so an admin SPN that isn't
          also in autoGroupsFromJwt matches nobody and no promotion
          happens.

          Fix: add each missing SPN to `operator.autoGroupsFromJwt`.
        '';
      }
    )

    {
      assertion = !cfg.routing.enable || cfg.operator.autoGroupsFromJwt != [ ];
      message = ''
        netbird: `routing.enable = true` requires
        `operator.autoGroupsFromJwt` to be non-empty. The routing
        Policy sources are resolved against pre-created Group CRs
        (one per SPN in `autoGroupsFromJwt`) that JWT-login peers
        attach to. With an empty list, no peer is ever a member
        of any policy source group and nothing is reachable.

        Fix: set `operator.autoGroupsFromJwt` to the list of SPN
        values your IdP puts in the JWT `groups` claim, e.g.
          [ "netbird-users@idm.example.test"
            "netbird-admins@idm.example.test" ]
      '';
    }

    (
      let
        routerGroups = lib.unique (lib.mapAttrsToList (_: n: n.routerGroup) cfg.routing.networks);
        offendingResources = lib.concatLists (
          lib.mapAttrsToList (
            _: n:
            lib.attrNames (
              lib.filterAttrs (_: v: lib.any (g: lib.elem g v.sourceGroups) routerGroups) n.resources
            )
          ) cfg.routing.networks
        );
        offendingAutoGroups = lib.filter (g: lib.elem g cfg.operator.autoGroupsFromJwt) routerGroups;
        offendsAutoGroups = offendingAutoGroups != [ ];
      in
      {
        assertion = !cfg.routing.enable || (offendingResources == [ ] && !offendsAutoGroups);
        message = ''
          netbird: a routing network's routerGroup is also referenced as a
          policy source or JWT auto-group:
            routerGroups: ${lib.concatStringsSep ", " routerGroups}
            resources.sourceGroups: ${lib.concatStringsSep ", " offendingResources}
            autoGroupsFromJwt: ${
              if offendsAutoGroups then lib.concatStringsSep ", " offendingAutoGroups else "(none)"
            }

          Upstream guidance: the router group belongs only in
          `NetworkRouter.peer_groups`. Using it elsewhere causes
          ACL overflow: the in-cluster router peer inherits
          every user policy, defeating role-scoped access.
          https://docs.netbird.io/how-to/networks

          Fix: rename either the network's `routerGroup` or the
          offending references so they don't overlap.
        '';
      }
    )

    (
      let
        allowedSources = cfg.operator.autoGroupsFromJwt;
        offenders = lib.concatLists (
          lib.mapAttrsToList (
            netName: n:
            lib.concatLists (
              lib.mapAttrsToList (
                rname: r:
                map (g: "${netName}/${rname}: '${g}'") (lib.filter (g: !(lib.elem g allowedSources)) r.sourceGroups)
              ) n.resources
            )
          ) cfg.routing.networks
        );
      in
      {
        assertion = !cfg.routing.enable || offenders == [ ];
        message = ''
          netbird: `routing.networks.<n>.resources.<r>.sourceGroups` references group name(s)
          not in `operator.autoGroupsFromJwt`:
            ${lib.concatStringsSep "\n                " offenders}

          Netbird's routing Policy rule targets peer groups by name, and a name
          not in autoGroupsFromJwt matches no peers (netbird never
          auto-creates a group by that name), so the resource is unreachable
          from ANY peer. Silent broken access is the default failure mode.

          Fix: either add the missing name to
            floes.netbird.operator.autoGroupsFromJwt
          (and make sure kanidm's claimMap projects a matching value if
          using `jwtGroupsClaimName != "groups"`), or correct the typo in
          `routing.resources.<n>.sourceGroups`.
        '';
      }
    )
  ];
in
{
  assertions = netbirdAssertions;

  warnings = lib.optional (cfg.versionCheck && !serverTagComparable) ''
    netbird: `managementImage` is pinned to "${serverTag}", which carries no
    comparable version, so the client↔server version check cannot run. A
    client/server skew here fails by hanging during registration rather
    than erroring. Pin a `<major>.<minor>.<patch>` tag to get the check back.
  '';
}
