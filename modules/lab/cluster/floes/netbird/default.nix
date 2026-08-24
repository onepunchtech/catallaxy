{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}:
let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions refs;
  planTokens = import ../../../../../lib/plan-tokens.nix { inherit lib; };
  cfg = config.floes.netbird;
in
{
  imports = [
    (floeOptions {
      name = "netbird";
      drift = [
        {
          group = "netbird.io";
          kinds = [
            "Group"
            "SetupKey"
          ];
          managedBy = [ "netbird-operator" ];
          reason = "netbird-operator writes reconciled state back onto the Group/SetupKey CRs it owns.";
        }
      ];
    })
    ./options.nix
    ./client-options.nix
    ./exports.nix
    ./bootstrap.nix
    ./routing.nix
    ./admin-reconciler.nix
    ./agent.nix
    ./operator.nix
  ];

  config = lib.mkIf cfg.enable (
    let

      nb = import ./lib.nix { inherit lib cfg; };

      inherit (lib)
        mkIf
        optionalAttrs
        optional
        ;

      inherit (nb)
        oauthRedirectUrls
        signalPort
        signalLegacyGrpcPort
        idpClientId
        idpIssuer
        idpJwksUri
        idpAuthorizationEndpoint
        idpBrowserTokenEndpoint
        idpPublicIssuer
        idpMachineTokenEndpoint
        idpMachineTokenRef
        hasCaBundle
        hasClientSecretRef
        signalDomain
        dashboardDomain
        apiTokenSecretName
        owner
        clusterRouterKeyName
        operatorKeyName
        jwtGroupUuidsSecretName
        setupKeySecretName
        setupKeySecretKey
        adminGroupsJson
        jwtDiscoverySpns
        jwtDiscoverySpnsJson
        defaultSetupKeys
        allSetupKeys
        defaultGroups
        spnSlug
        autoGroupCrDefs
        allGroups
        waitTimeoutSeconds
        waitTimeoutStr
        ;

      mkWaitForSecrets =
        secrets:
        map (
          s:
          k8sHelpers.wait.mkWaitInitContainer {
            name = "wait-for-${s.name}";
            probe = {
              kind = "jsonpath";
              resource = "secret/${s.secret}";
              namespace = cfg.namespace;
              jsonpath = "{.data.${s.key}}";
              timeout = waitTimeoutStr;
            };
          }
        ) secrets;

      sectionName = config.floes.gateway.exports.terminatingListenerName or "https";

      internalGatewayName = config.floes.gateway.exports.internalGatewayName;

      inherit (config.floes.gateway.exports) gatewayName;

      gatewayNamespace = config.floes.gateway.exports.namespace;

      routes = import ./routes.nix {
        inherit
          lib
          cfg
          nb
          k8sHelpers
          sectionName
          gatewayName
          gatewayNamespace
          ;
      };

      mgmtRouteResource = routes.routes;

      mgmtCertResource = routes.cert;

      dashboard = import ./dashboard.nix {
        inherit
          lib
          cfg
          nb
          k8sHelpers
          sectionName
          internalGatewayName
          gatewayName
          gatewayNamespace
          ;
      };

      dashboardResources = dashboard.resources;

      dashboardCertResource = dashboard.cert;

      management = import ./management.nix {
        inherit
          lib
          cfg
          nb
          k8sHelpers
          mkWaitForSecrets
          ;
      };

      inherit (management) managementConfigJson;

      netbirdMgmtResources = management.resources;

      netbirdSignalResources = import ./signal.nix { inherit cfg nb; };

      netbirdRelayResources = import ./relay.nix { inherit cfg nb; };

      netbirdClient = import ./client.nix {
        inherit lib pkgs;
        client = cfg.client;
      };

      ops = import ./ops.nix {
        inherit
          lib
          pkgs
          cfg
          nb
          ;
        client = netbirdClient;
        kubeContext = config.cluster.ref.kubeContext;
      };

      netbirdOpsScripts = {
        inherit (ops)
          status
          logout
          peers
          routes
          ;

        login = import ./ops-login.nix {
          inherit
            lib
            pkgs
            cfg
            managementConfigJson
            ;
          inherit (ops) mkNetbirdOpsScript;
        };

        check-config = import ./ops-check-config.nix {
          inherit pkgs cfg nb;
          inherit (ops) mkNetbirdOpsScript;
        };
      };

      peerEnabled = req: (config.floes.${req} or { }).enable or false;

      netbirdChecks = import ./assertions.nix {
        inherit
          lib
          cfg
          nb
          peerEnabled
          ;
      };

    in
    lib.mkMerge [
      {
        inherit (netbirdChecks) assertions warnings;

        floes.netbird.images = {
          management = {
            repository = "netbirdio/management";
            tag = cfg.version;
          };
          signal = {
            repository = "netbirdio/signal";
            tag = cfg.version;
          };
          relay = {
            repository = "netbirdio/relay";
            tag = cfg.version;
          };
          agent = {
            repository = "netbirdio/netbird";
            tag = cfg.version;
          };
          dashboard = {
            repository = "netbirdio/dashboard";
            tag = "main";
          };
          bootstrap = {
            repository = "alpine/k8s";
            tag = "1.32.4";
          };
          wait = {
            repository = "busybox";
            tag = "1.36";
          };
        };

        floes.netbird.gateway.extraDomains = [ signalDomain ];

        floes.netbird.routing.sourceGroups = lib.mkDefault cfg.operator.autoGroupsFromJwt;

        floes.netbird.exports =
          let
            host = "netbird-management.${cfg.namespace}.svc.cluster.local";
          in
          {
            inherit host signalDomain;
            namespace = cfg.namespace;
            hostClient = {
              inherit (netbirdClient) cli;
              joinBin = "${netbirdOpsScripts.login}/bin/login";
              leaveBin = "${netbirdOpsScripts.logout}/bin/logout";
              inherit (cfg.client) package;
            };
            managementUrl = "https://${cfg.domain}";
            managementInternalUrl = "http://${host}:80";
            signalHost = "netbird-signal.${cfg.namespace}.svc.cluster.local";
            inherit signalPort;
            domain = cfg.domain;

            inherit oauthRedirectUrls;
            clusterRouterSecret = setupKeySecretName clusterRouterKeyName;
            operatorSecret = setupKeySecretName operatorKeyName;
            setupKeyDataKey = setupKeySecretKey;
            apiTokenSecretName = apiTokenSecretName;
          };

      }

      (mkIf (cfg.enable && cfg.management.enable) {
        floes.netbird.ops.netbird.login = {

          description = "Join the lab's Netbird mesh (browser SSO via kanidm)";
          package = netbirdOpsScripts.login;
        };
        floes.netbird.ops.netbird.logout = {
          description = "Leave the lab's Netbird mesh and stop its daemon";
          package = netbirdOpsScripts.logout;
        };
        floes.netbird.ops.netbird.status = {
          description = "Show this lab's netbird client status (not your own daemon's)";
          package = netbirdOpsScripts.status;
        };
        floes.netbird.ops.netbird.peers = {
          description = "List peers registered with the lab's Netbird management server";
          package = netbirdOpsScripts.peers;
        };
        floes.netbird.ops.netbird.routes = {
          description = "List routes registered with the lab's Netbird management server";
          package = netbirdOpsScripts.routes;
        };
        floes.netbird.ops.netbird.check-config = {
          description = "Preflight: validate OIDC wiring against the live IdP from inside the netbird namespace";
          package = netbirdOpsScripts.check-config;
        };
      })

      (mkIf (cfg.enable && cfg.management.enable) {
        # Both are read back as bytes rather than as strings: the datastore
        # key is base64 of a 32-byte AES key, and the relay secret keys an
        # HMAC. base64 encoding satisfies either reading.
        floes.netbird.secrets.generate = {
          netbird-datastore-enc-key = {
            inherit (cfg) namespace;
            key = "key";
            length = 32;
            encoding = "base64";
          };
          netbird-relay-secret = {
            inherit (cfg) namespace;
            key = "netbird-relay-secret-key";
            length = 32;
            encoding = "base64";
          };
        };

      })

      (mkIf (cfg.enable && cfg.management.enable) {
        floes.netbird.bundles.netbird = {
          inherit owner;
          resources =
            netbirdMgmtResources
            // netbirdSignalResources
            // netbirdRelayResources
            // mgmtRouteResource
            // mgmtCertResource
            // dashboardResources
            // dashboardCertResource;
          createNamespaces = [ cfg.namespace ];

          requires = [

            "netbird/prechart/ready"
          ]
          ++ lib.optional (hasCaBundle && cfg.tls.caBundle.readyToken != null) cfg.tls.caBundle.readyToken;

          after = [ "optional:identity/instance/ready" ];
          provides = [ "netbird/management/ready" ];
          readyProbe = {
            kind = "condition";
            resource = "deployment/netbird-management";
            namespace = cfg.namespace;
            condition = "Available";
            timeout = "10m";
          };
        };

        floes.gateway.internalHostnames = lib.mkIf (
          cfg.dashboard.enable && cfg.dashboard.gateway.tier == "internal"
        ) [ dashboardDomain ];
      })

      (mkIf (cfg.operator.enable && hasClientSecretRef) {

        shell.packages = [ netbirdClient.cli ];

        floes.netbird.steps.netbird-mesh-join = {
          kind = "run-script";
          direction = "deploy";
          description = "Join this lab's netbird mesh";

          scope = "lab";
          provides = [
            "netbird/mesh/joined"
            planTokens.lab.reachable
          ];
          after = planTokens.wantsAll [
            (planTokens.cluster config.cluster.name).deployed
            planTokens.lab.hostTrust
            planTokens.lab.hostDns
          ];
          params.bin = "${netbirdOpsScripts.login}/bin/login";
          policy.interactive = true;
        };

        floes.netbird.steps.netbird-mesh-leave = {
          kind = "run-script";
          direction = "teardown";
          description = "Leave the lab mesh and stop this lab's netbird daemon";
          provides = [
            planTokens.lab.cleanup
            (planTokens.cluster config.cluster.name).cleanup
          ];

          after = [ (planTokens.wants "netbird/agent-deregistered") ];
          policy.onFailure = "continue";
          params.bin = "${netbirdOpsScripts.logout}/bin/logout";
        };
      })

    ]
  );
}
