{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;
  netbird = import ../../../modules/lab/cluster/floes/netbird;

  baseStubs = {
    args = {
      cataCharts.netbird-operator = {
        chart = pkgs.emptyDirectory;
        crds = null;
        version = "0.0.0-stub";
      };

      inherit pkgs;
    };
  };

  stubUpstreamOptions =
    { lib, ... }:
    {

      config._module.freeformType = lib.types.attrs;
      options.components = lib.mkOption {
        type = lib.types.attrsOf lib.types.attrs;
        default = { };
      };
      options.cluster.ref.kubeContext = lib.mkOption {
        type = lib.types.str;
        default = "stub-ctx";
      };

      options.floes.gateway.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      options.floes.kanidm.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      options.floes.kaniop.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      options.floes.cert-manager.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      options.floes.kanidm.exports = lib.mkOption {
        type = lib.types.attrs;
        default = {
          identity = null;
          oauth2Clients = { };
        };
      };
      options.floes.cert-manager.exports = lib.mkOption {
        type = lib.types.attrs;
        default = {
          caBundle = null;
          issuance = null;
        };
      };
      options.floes.gateway.exports = lib.mkOption {
        type = lib.types.attrs;
        default = {
          internalDomain = "internal.test.local";
          gatewayName = "stub-gateway";
          namespace = "kube-system";
          defaultTier = "public";
        };
      };
    };

  disabledResult = evalFloe (
    {
      floe = netbird;
      cluster = {
        imports = [ stubUpstreamOptions ];
        floes.netbird.enable = false;
      };
    }
    // baseStubs
  );

  labCaBundle = {
    name = "lab-ca-bundle";
    key = "ca.crt";
    readyToken = null;
    readyProbe = null;
  };

  validEnabledCluster = {
    imports = [ stubUpstreamOptions ];
    floes.gateway.enable = true;
    floes.kanidm.enable = true;
    floes.kaniop.enable = true;
    floes.cert-manager.enable = true;
    floes.cert-manager.exports = {
      caBundle = labCaBundle;
      issuance = null;
    };
    floes.kanidm.exports = {
      identity = {
        instanceReady = "kanidm/instance/ready";
        provisioningReady = "kanidm/provisioning/ready";
      };
      oauth2Clients = { };
    };
    floes.netbird = {
      enable = true;
      domain = "vpn.test.local";
      idp = {

        client = {
          issuer = "https://idm.test.local/oauth2/openid/netbird";
          clientId = "netbird";
          publicIssuer = "https://idm.test.local/oauth2/openid/netbird";
          jwksUri = "https://kanidm.kanidm.svc.cluster.local:8443/oauth2/openid/netbird/public_key.jwk";
          authorizationEndpoint = "https://idm.test.local/ui/oauth2";
          tokenEndpoint = "https://idm.test.local/oauth2/token";
        };

        machine = {
          tokenEndpoint = "https://kanidm.kanidm.svc.cluster.local:8443/oauth2/token";
          tokenRef = {
            name = "kanidm-bot-token";
            namespace = "kanidm";
            key = "token";
          };
        };
      };
      tls.issuerRef = {
        name = "lab-ca";
        kind = "ClusterIssuer";
      };
      operator.enable = true;
      routing.enable = false;
      agent = {
        enable = true;
        managementUrl = "https://vpn.test.local";
        setupKeyRef.name = "setup-key-cluster-router";
      };
    };
  };

  enabledResult = evalFloe (
    {
      floe = netbird;
      cluster = validEnabledCluster;
    }
    // baseStubs
  );

  noMachineCredsResult = evalFloe (
    {
      floe = netbird;
      cluster = lib.recursiveUpdate validEnabledCluster {
        floes.netbird.idp.machine = lib.mkForce null;
      };
    }
    // baseStubs
  );

  tunedWaitResult = evalFloe (
    {
      floe = netbird;
      cluster = lib.recursiveUpdate validEnabledCluster {
        floes.netbird.wait.attempts = 7;
      };
    }
    // baseStubs
  );

  peerOnlyResult = evalFloe (
    {
      floe = netbird;
      cluster = {
        imports = [ stubUpstreamOptions ];
        floes.cert-manager.exports = {
          caBundle = labCaBundle;
          issuance = null;
        };
        floes.netbird = {
          enable = true;
          management.enable = false;
          domain = "vpn.test.local";
          agent = {
            enable = true;
            managementUrl = "https://vpn.test.local";
            setupKeyRef.name = "setup-key-cluster-router";
            advertisedRoutes = [ "10.112.0.0/12" ];
          };
        };
      };
    }
    // baseStubs
  );

  jwksWithoutBrowserEndpoints = evalFloe (
    {
      floe = netbird;
      cluster = lib.recursiveUpdate validEnabledCluster {
        floes.netbird.idp.client.authorizationEndpoint = lib.mkForce "";
      };
    }
    // baseStubs
  );

  noInternalTierResult = evalFloe (
    {
      floe = netbird;
      cluster = lib.recursiveUpdate validEnabledCluster {
        floes.gateway.exports = lib.mkForce { internalDomain = ""; };
      };
    }
    // baseStubs
  );

  agentWithoutCaBundle = evalFloe (
    {
      floe = netbird;
      cluster = lib.recursiveUpdate validEnabledCluster {
        floes.cert-manager.exports.caBundle = lib.mkForce null;
        floes.netbird.tls.caBundle = lib.mkForce null;
      };
    }
    // baseStubs
  );

  forcePromptResult = evalFloe (
    {
      floe = netbird;
      cluster = lib.recursiveUpdate validEnabledCluster {
        floes.netbird.sso.forcePrompt = true;
      };
    }
    // baseStubs
  );

  peerBundles = lib.attrNames (peerOnlyResult.config.bundles or { });

  mgmtDeployment = (enabledResult.config.bundles.netbird.resources or { }).netbird-management or null;

  mgmtInitContainerNames =
    if mgmtDeployment != null then
      map (c: c.name) mgmtDeployment.spec.template.spec.initContainers
    else
      [ ];

  tunedAgentDeployment =
    (tunedWaitResult.config.bundles.netbird-agent.resources or { }).netbird-agent or null;

  tunedAgentWaitScript =
    if tunedAgentDeployment != null then
      let
        waiter = lib.findFirst (
          c: c.name == "wait-for-setup-key"
        ) null tunedAgentDeployment.spec.template.spec.initContainers;
      in
      if waiter != null then builtins.head waiter.args else ""
    else
      "";
  mgmtConfigMap =
    (enabledResult.config.bundles.netbird.resources or { }).netbird-management-cm or null;

  mgmtRedirectUrls =
    if mgmtConfigMap != null then
      (builtins.fromJSON mgmtConfigMap.data."management.tmpl.json")
      .PKCEAuthorizationFlow.ProviderConfig.RedirectURLs
    else
      [ ];
in
lib.runTests {

  testNetbirdOptionsDeclared = {
    expr = disabledResult.config.floes.netbird ? enable;
    expected = true;
  };

  testDisabledEmitsNothing = {
    expr = disabledResult.config.bundles;
    expected = { };
  };

  testProvidesShape = {
    expr = builtins.isAttrs disabledResult.config.floes.netbird.exports;
    expected = true;
  };

  testOverridesDefaults = {
    expr = disabledResult.config.floes.netbird.overrides.serviceType;
    expected = "ClusterIP";
  };

  testValidConfigPassesAllAssertions = {
    expr = builtins.filter (a: !a.assertion) enabledResult.config.assertions;
    expected = [ ];
  };

  testJwksWithoutBrowserEndpointsAsserts = {
    expr =
      builtins.length (builtins.filter (a: !a.assertion) jwksWithoutBrowserEndpoints.config.assertions)
      == 1;
    expected = true;
  };

  testNoMachineCredsIsValid = {
    expr = builtins.filter (a: !a.assertion) noMachineCredsResult.config.assertions;
    expected = [ ];
  };

  testNoMachineCredsDropsBootstrapJob = {
    expr = lib.filter (b: lib.hasInfix "bootstrap" b) (
      builtins.attrNames (noMachineCredsResult.config.bundles or { })
    );
    expected = [ ];
  };

  testManagementInitContainersPresent = {
    expr =
      builtins.elem "wait-for-relay-secret" mgmtInitContainerNames
      && builtins.elem "wait-for-datastore-enc-key" mgmtInitContainerNames;
    expected = true;
  };

  testWaitInitRunsBeforeConfigure = {
    expr =
      let
        idxRelay = lib.lists.findFirstIndex (n: n == "wait-for-relay-secret") null mgmtInitContainerNames;
        idxConfigure = lib.lists.findFirstIndex (n: n == "configure") null mgmtInitContainerNames;
      in
      idxRelay != null && idxConfigure != null && idxRelay < idxConfigure;
    expected = true;
  };

  testWaitTimeoutPropagates = {
    expr =
      let
        cmd =
          (lib.findFirst (
            c: c.name == "wait-for-setup-key"
          ) null tunedAgentDeployment.spec.template.spec.initContainers).args;
        script = builtins.head cmd;
      in
      lib.hasInfix "--timeout=35s" script;
    expected = true;
  };

  testPeerOnlyDropsControlPlane = {
    expr = lib.filter (
      b:
      builtins.elem b [
        "netbird"
        "netbird-prechart"
        "netbird-bootstrap"
      ]
    ) peerBundles;
    expected = [ ];
  };

  testPeerOnlyKeepsAgent = {
    expr = builtins.elem "netbird-agent" peerBundles;
    expected = true;
  };

  testPeerOnlyDropsOperator = {
    expr = lib.filter (b: lib.hasPrefix "netbird-operator" b) peerBundles;
    expected = [ ];
  };

  testPeerOnlyHasNoFailedAssertions = {
    expr = map (a: a.message) (builtins.filter (a: !a.assertion) peerOnlyResult.config.assertions);
    expected = [ ];
  };

  # A peer cluster used to defer this, because its setup key arrived after
  # the deploy via a copy step. The key is projected during the deploy now,
  # so the peer waits like anything else.
  testPeerOnlyAwaitsAgentRollout = {
    expr = peerOnlyResult.config.bundles.netbird-agent.awaitRollout or null;
    expected = true;
  };

  # And the wait is on the key itself, not merely on the Deployment, on both
  # kinds of cluster.
  testAgentGatesOnItsSetupKeySecret = {
    expr = map (r: r.resource) [
      peerOnlyResult.config.bundles.netbird-agent.readyProbe
      enabledResult.config.bundles.netbird-agent.readyProbe
    ];
    expected = [
      "secret/setup-key-cluster-router"
      "secret/setup-key-cluster-router"
    ];
  };

  testManagementAwaitsAgentRollout = {
    expr = enabledResult.config.bundles.netbird-agent.awaitRollout or null;
    expected = true;
  };

  testPushedDnsDomainsComeFromTheGateway = {
    expr = enabledResult.config.floes.netbird.routing.dnsDomains;
    expected = [
      "internal.test.local"
      "svc.cluster.local"
    ];
  };

  testNoInternalTierPushesNoDomains = {
    expr = noInternalTierResult.config.floes.netbird.routing.dnsDomains;
    expected = [ ];
  };

  testHttpsAgentWithoutACaBundleIsRejected = {
    expr = builtins.length (
      builtins.filter (
        a: !a.assertion && lib.hasInfix "no CA to verify it with" a.message
      ) agentWithoutCaBundle.config.assertions
    );
    expected = 1;
  };

  testDaemonLogLevelIsDeclaredAndQuietByDefault = {
    expr = disabledResult.config.floes.netbird.client.logLevel;
    expected = "info";
  };

  testLiveIdpSessionIsNotForcedToReauthenticate = {
    expr =
      (builtins.fromJSON mgmtConfigMap.data."management.tmpl.json")
      .PKCEAuthorizationFlow.ProviderConfig.DisablePromptLogin;
    expected = true;
  };

  testForcePromptReinstatesTheCredentialPrompt = {
    expr =
      let
        cm = (forcePromptResult.config.bundles.netbird.resources or { }).netbird-management-cm;
      in
      (builtins.fromJSON cm.data."management.tmpl.json")
      .PKCEAuthorizationFlow.ProviderConfig.DisablePromptLogin;
    expected = false;
  };

  testGrpcBackendsAreReachedOverH2c = {
    expr =
      let
        resources = enabledResult.config.bundles.netbird.resources or { };
        routedPortAppProtocol =
          service:
          let
            route = resources."${service}-route";
            backend = builtins.head (builtins.head route.spec.rules).backendRefs;
            port = lib.findFirst (p: p.port == backend.port) null resources."${service}-svc".spec.ports;
          in
          port.appProtocol or null;
      in
      map routedPortAppProtocol [
        "netbird-management"
        "netbird-signal"
      ];
    expected = [
      "kubernetes.io/h2c"
      "kubernetes.io/h2c"
    ];
  };

  testSignalExportNamesThePrimaryListener = {
    expr =
      let
        svc = (enabledResult.config.bundles.netbird.resources or { }).netbird-signal-svc;
        named = lib.findFirst (p: p.name == "http") null svc.spec.ports;
      in
      named.port == enabledResult.config.floes.netbird.exports.signalPort;
    expected = true;
  };

  testSignalRouteTargetsThePrimaryListener = {
    expr =
      let
        route = (enabledResult.config.bundles.netbird.resources or { }).netbird-signal-route;
        backend = builtins.head (builtins.head route.spec.rules).backendRefs;
      in
      backend.port == enabledResult.config.floes.netbird.exports.signalPort;
    expected = true;
  };

  testSignalServesTheExportedPort = {
    expr =
      let
        deploy = (enabledResult.config.bundles.netbird.resources or { }).netbird-signal;
        args = (builtins.head deploy.spec.template.spec.containers).args;
        portArg = builtins.elemAt args ((lib.lists.findFirstIndex (a: a == "--port") null args) + 1);
      in
      portArg == toString enabledResult.config.floes.netbird.exports.signalPort;
    expected = true;
  };

  testSignalKeepsTheLegacyGrpcCompatPort = {
    expr =
      let
        svc = (enabledResult.config.bundles.netbird.resources or { }).netbird-signal-svc;
      in
      (lib.findFirst (p: p.name == "grpc-compat") null svc.spec.ports).port;
    expected = 10000;
  };

  testDisabledExportsNoRedirectUrls = {
    expr = disabledResult.config.floes.netbird.exports.oauthRedirectUrls;
    expected = [ ];
  };

  testRedirectUrlsFollowCallbackPorts = {
    expr = enabledResult.config.floes.netbird.exports.oauthRedirectUrls;
    expected = [
      "http://localhost:53010/"
      "http://localhost:53011/"
      "http://localhost:53012/"
      "http://localhost:53013/"
    ];
  };

  testCallbackPortsAvoidTheOperatorsOwnDaemon = {
    expr = builtins.elem 53000 enabledResult.config.floes.netbird.client.callbackPorts;
    expected = false;
  };

  testManagementOffersEveryCallbackPort = {
    expr = mgmtRedirectUrls == enabledResult.config.floes.netbird.exports.oauthRedirectUrls;
    expected = true;
  };

  testMoreThanOneCallbackPortIsOffered = {
    expr = builtins.length mgmtRedirectUrls >= 2;
    expected = true;
  };

  # The relay secret and the datastore encryption key used to come from two
  # Jobs that shelled out to /dev/urandom and skipped themselves if the Secret
  # already existed. They are generated now, so the prechart bundle carries
  # only the RBAC the other bootstrap Jobs run under.
  testTheMintJobsAreGone = {
    expr = lib.filter (lib.hasInfix "mint") (
      builtins.attrNames (enabledResult.config.bundles.netbird-prechart.resources or { })
    );
    expected = [ ];
  };

  testThePrechartBundleStillProvidesItsToken = {
    expr = enabledResult.config.bundles.netbird-prechart.provides or [ ];
    expected = [ "netbird/prechart/ready" ];
  };
}
