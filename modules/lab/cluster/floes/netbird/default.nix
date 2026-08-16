{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}@__floeModuleArgs:
let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
  planTokens = import ../../../../../lib/plan-tokens.nix { inherit lib; };
in
(mkFloe {
  name = "netbird";

  imports = [ ./options.nix ];

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

  requires = [ ];

  exports =
    { lib, ... }:
    {
      namespace = lib.mkOption {
        type = lib.types.str;
        default = "netbird";
        description = "Kubernetes namespace the management plane runs in.";
      };
      domain = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Public FQDN of the netbird management dashboard (echoes cfg.domain).";
      };
      signalDomain = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Public FQDN of the netbird signal service.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "In-cluster DNS name of the management Service.";
      };
      managementUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          External management URL (https). Agents outside the cluster
          (operator laptops joined to the mesh) point at this.
        '';
      };
      hostClient = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          This lab's host-side netbird, for a lab that wants to drive the
          mesh itself rather than take the `netbird-mesh-join` /
          `netbird-mesh-leave` steps the floe declares:

            cli      : wrapper carrying this lab's --service /
                       --daemon-addr / --config / --log-file, so an
                       invocation cannot reach the operator's own daemon
            joinBin  : the SSO login the join step runs
            leaveBin : the counterpart the leave step runs
            package  : the netbird derivation everything above is built
                       from, and the version all four server images follow

          Empty when the floe is disabled, so a consumer reading it in an
          option default gets `{ }` rather than an eval error.
        '';
      };
      managementInternalUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          In-cluster management URL (http). Agents running as Pods
          inside the same cluster should use this, which avoids a hairpin
          through the public gateway and the TLS-terminating LB.
        '';
      };
      signalHost = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "In-cluster DNS name of the signal Service.";
      };
      signalPort = lib.mkOption {
        type = lib.types.port;
        default = 80;
        description = ''
          In-cluster port for the signal Service: the primary listener,
          serving gRPC over HTTP with the WebSocket proxy, which is what
          a current agent dials.

          The Service also carries `grpc-compat` on 10000. That is
          netbird's legacy bare-gRPC listener, which signal runs only to
          keep agents that were already connected on the old default
          port from dropping. Dialing it for a new connection is not the
          supported path.
        '';
      };
      oauthRedirectUrls = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Loopback callback URLs this lab's `netbird up` may listen on,
          derived from `client.callbackPorts`.

          The IdP client that netbird logs in through must register every
          one of them: netbird picks whichever port is free at login
          time, and an unregistered redirect URI is refused by the IdP.
          Read this rather than restating the literals; the port set is
          netbird's to choose.
        '';
      };
      clusterRouterSecret = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Name of the Secret holding the cluster-router SetupKey. The
          operator's `netbird-agent` in-cluster Pod reads this to join
          the mesh as a routing peer.
        '';
      };
      operatorSecret = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Name of the Secret holding the operator SetupKey, used to
          onboard human operator devices.
        '';
      };
      setupKeyDataKey = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Data key inside the SetupKey Secrets that holds the key value.";
      };
      apiTokenSecretName = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Name of the Secret holding the PAT used by the bootstrap Job
          to call netbird's management API for one-time provisioning.
        '';
      };
    };
  module =
    {
      config,
      lib,
      pkgs,
      cataCharts,
      k8sHelpers,
      cfg,
      peers,
      ...
    }:
    let

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
      inherit (lib)
        mkOption
        mkEnableOption
        mkIf
        types
        optionalAttrs
        optional
        mapAttrsToList
        ;
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

      apiTokenSecretName = cfg.operator.apiTokenSecretName;
      clusterRouterKeyName = "cluster-router";
      operatorKeyName = "operator";

      jwtGroupUuidsSecretName = "netbird-jwt-group-uuids";

      adminGroupsJson = builtins.toJSON cfg.operator.adminGroupsFromJwt;

      jwtDiscoverySpns = lib.unique (
        cfg.operator.adminGroupsFromJwt
        ++ cfg.operator.autoGroupsFromJwt
        ++ (cfg.routing.sourceGroups or [ ])
      );
      jwtDiscoverySpnsJson = builtins.toJSON jwtDiscoverySpns;

      setupKeySecretName = name: "setup-key-${name}";
      setupKeySecretKey = "setup-key";

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

      groupResources = lib.mapAttrs' (
        name: def:
        lib.nameValuePair "netbird-group-${name}" {
          apiVersion = "netbird.io/v1alpha1";
          kind = "Group";
          metadata = {
            inherit name;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            name = def.specName;
          };
        }
      ) allGroups;

      setupKeyResources = lib.mapAttrs' (
        name: spec:
        lib.nameValuePair "netbird-setupkey-${name}" {
          apiVersion = "netbird.io/v1alpha1";
          kind = "SetupKey";
          metadata = {
            inherit name;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            inherit name;
            ephemeral = spec.ephemeral or false;
            allowExtraDnsLabels = false;
            duration = spec.duration or "8760h";
            autoGroups = map (g: {
              localRef = {
                name = g;
              };
            }) (spec.autoGroups or [ ]);
          };
        }
      ) allSetupKeys;

      mgmtRouteResource = {
        netbird-management-route = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            name = "netbird-management";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [
              {
                name = "default-gateway";
                namespace = "kube-system";
                sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
              }
            ];
            hostnames = [ cfg.domain ];
            rules = [
              {
                matches = [
                  {
                    path = {
                      type = "PathPrefix";
                      value = "/";
                    };
                  }
                ];
                backendRefs = [
                  {
                    name = "netbird-management";
                    port = 80;
                  }
                ];
              }
            ];
          };
        };

        netbird-relay-route = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            name = "netbird-relay";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [
              {
                name = "default-gateway";
                namespace = "kube-system";
                sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
              }
            ];
            hostnames = [ cfg.domain ];
            rules = [
              {
                matches = [
                  {
                    path = {
                      type = "PathPrefix";
                      value = "/relay";
                    };
                  }
                ];
                backendRefs = [
                  {
                    name = "netbird-relay";
                    port = 33080;
                  }
                ];
              }
            ];
          };
        };

        netbird-signal-route = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            name = "netbird-signal";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [
              {
                name = "default-gateway";
                namespace = "kube-system";
                sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
              }
            ];
            hostnames = [ signalDomain ];
            rules = [
              {
                matches = [
                  {
                    path = {
                      type = "PathPrefix";
                      value = "/";
                    };
                  }
                ];
                backendRefs = [
                  {
                    name = "netbird-signal";
                    port = signalPort;
                  }
                ];
              }
            ];
          };
        };
      };

      mgmtCertResource = optionalAttrs (cfg.tls.issuerRef != null) {
        netbird-management-tls = {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          metadata = {
            name = cfg.tls.secretName;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            secretName = cfg.tls.secretName;
            issuerRef = {
              name = cfg.tls.issuerRef.name;
              kind = cfg.tls.issuerRef.kind;
            };
            dnsNames = [
              cfg.domain
              signalDomain
            ];
          };
        };
      };

      dashboardDomain =
        if cfg.dashboard.domain != "" then
          cfg.dashboard.domain
        else
          let
            parts = lib.splitString "." cfg.domain;
            parent = lib.concatStringsSep "." (lib.tail parts);
          in
          "nb-dashboard.${parent}";

      dashboardEnv = [
        {
          name = "AUTH_AUDIENCE";
          value = cfg.dashboard.oidc.clientId;
        }
        {
          name = "AUTH_CLIENT_ID";
          value = cfg.dashboard.oidc.clientId;
        }
        {
          name = "AUTH_AUTHORITY";
          value = cfg.dashboard.oidc.issuerUrl;
        }
        {
          name = "USE_AUTH0";
          value = "false";
        }
        {
          name = "AUTH_SUPPORTED_SCOPES";
          value = lib.concatStringsSep " " cfg.dashboard.oidc.scopes;
        }
        {
          name = "AUTH_REDIRECT_URI";
          value = cfg.dashboard.oidc.authRedirectPath;
        }
        {
          name = "AUTH_SILENT_REDIRECT_URI";
          value = cfg.dashboard.oidc.silentRedirectPath;
        }
        {
          name = "NETBIRD_TOKEN_SOURCE";
          value = "idToken";
        }
        {
          name = "NETBIRD_MGMT_API_ENDPOINT";
          value = "https://${cfg.domain}";
        }
        {
          name = "NETBIRD_MGMT_GRPC_API_ENDPOINT";
          value = "https://${cfg.domain}";
        }

        {
          name = "NGINX_PID";
          value = "/tmp/nginx.pid";
        }
      ];

      dashboardResources = optionalAttrs cfg.dashboard.enable {
        netbird-dashboard-svc = {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            name = "netbird-dashboard";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            type = "ClusterIP";
            selector."app.kubernetes.io/name" = "netbird-dashboard";
            ports = [
              {
                name = "http";
                port = 80;

                targetPort = 80;
              }
            ];
          };
        };

        netbird-dashboard = {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            name = "netbird-dashboard";
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/name" = "netbird-dashboard";
              "app.kubernetes.io/managed-by" = "catallaxy";
            };
          };
          spec = {
            replicas = cfg.dashboard.replicas;
            selector.matchLabels."app.kubernetes.io/name" = "netbird-dashboard";
            template = {
              metadata.labels."app.kubernetes.io/name" = "netbird-dashboard";
              spec = {
                containers = [
                  {
                    name = "dashboard";
                    image = cfg.images.dashboard.ref;
                    env = dashboardEnv;
                    ports = [
                      {
                        name = "http";

                        containerPort = 80;
                      }
                    ];
                    resources = cfg.dashboard.resources;

                    volumeMounts = [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                    ];
                  }
                ];
                volumes = [
                  {
                    name = "tmp";
                    emptyDir = { };
                  }
                ];
              };
            };
          };
        };

        netbird-dashboard-route = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            name = "netbird-dashboard";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [
              {
                name =
                  if cfg.dashboard.gateway.tier == "internal" then
                    config.floes.gateway.exports.internalGatewayName
                  else
                    "default-gateway";
                namespace = "kube-system";
                sectionName = config.floes.gateway.exports.terminatingListenerName or "https";
              }
            ];
            hostnames = [ dashboardDomain ];
            rules = [
              {
                matches = [
                  {
                    path = {
                      type = "PathPrefix";
                      value = "/";
                    };
                  }
                ];
                backendRefs = [
                  {
                    name = "netbird-dashboard";
                    port = 80;
                  }
                ];
              }
            ];
          };
        };
      };

      dashboardCertResource = optionalAttrs (cfg.dashboard.enable && cfg.tls.issuerRef != null) {
        netbird-dashboard-tls = {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          metadata = {
            name = cfg.dashboard.tls.secretName;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            secretName = cfg.dashboard.tls.secretName;
            issuerRef = {
              name = cfg.tls.issuerRef.name;
              kind = cfg.tls.issuerRef.kind;
            };
            dnsNames = [ dashboardDomain ];
          };
        };
      };

      managementConfigJson = builtins.toJSON {

        Stuns = lib.optional cfg.stun.enable {
          Proto = "udp";
          URI = "stun:${cfg.stun.domain}:3478";
          Username = "";
          Password = null;
        };
        TURNConfig = {
          Turns = lib.optional cfg.turn.enable {
            Proto = "udp";
            URI = "turn:${cfg.turn.domain}:3478";
            Username = "";
            Password = "";
          };
          CredentialsTTL = "12h";
          Secret = "secret";
          TimeBasedCredentials = false;
        };
        Relay = {

          Addresses = [ "rels://${cfg.domain}" ];
          CredentialsTTL = "24h";
          Secret = "@RELAY_AUTH_SECRET@";
        };
        StoreConfig = {
          Engine = "sqlite";
        };
        Signal = {
          Proto = "https";
          URI = "${signalDomain}:443";
          Username = "";
          Password = null;
        };

        ReverseProxy = {
          TrustedHTTPProxies = [ ];
          TrustedHTTPProxiesCount = 0;
          TrustedPeers = [ "0.0.0.0/0" ];
        };
        DisableDefaultPolicy = true;
        Datadir = "";

        DataStoreEncryptionKey = "@DATASTORE_ENC_KEY@";
        HttpConfig = {
          Address = "0.0.0.0:80";

          AuthAudience = idpClientId;
          AuthUserIDClaim = "sub";
          CertFile = "";
          CertKey = "";
          IdpSignKeyRefreshEnabled = true;
        }
        // (
          if idpJwksUri != "" then
            {
              AuthIssuer = idpPublicIssuer;
              AuthKeysLocation = idpJwksUri;
            }
          else
            { OIDCConfigEndpoint = "${idpIssuer}/.well-known/openid-configuration"; }
        );

        IdpManagerConfig = {
          ManagerType = "none";
          ClientConfig = {
            Issuer = "";
            TokenEndpoint = "";
            ClientID = "";
            ClientSecret = "";
            GrantType = "";
          };
          ExtraConfig = { };
          Auth0ClientCredentials = null;
          AzureClientCredentials = null;
          KeycloakClientCredentials = null;
          ZitadelClientCredentials = null;
        };

        DeviceAuthorizationFlow = null;

        PKCEAuthorizationFlow = {
          ProviderConfig = {
            Audience = idpClientId;
            ClientID = idpClientId;
            ClientSecret = "";
            AuthorizationEndpoint = idpAuthorizationEndpoint;
            TokenEndpoint = idpBrowserTokenEndpoint;
            Domain = "";

            Scope = "openid profile email offline_access groups";
            UseIDToken = true;
            RedirectURLs = oauthRedirectUrls;

            DisablePromptLogin = !cfg.sso.forcePrompt;
            LoginFlag = 0;
          };
        };
      };

      netbirdMgmtResources = {
        netbird-management-sa = {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = "netbird-management";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
        };

        netbird-management-secret-reader = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = "netbird-management-secret-reader";
            namespace = cfg.namespace;
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              verbs = [
                "get"
                "list"
              ];
            }
          ];
        };

        netbird-management-secret-reader-binding = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          metadata = {
            name = "netbird-management-secret-reader";
            namespace = cfg.namespace;
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "netbird-management-secret-reader";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "netbird-management";
              namespace = cfg.namespace;
            }
          ];
        };

        netbird-management-pvc = {
          apiVersion = "v1";
          kind = "PersistentVolumeClaim";
          metadata = {
            name = "netbird-management";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = cfg.management.storage.size;
          }
          // optionalAttrs (cfg.management.storage.storageClass != null) {
            storageClassName = cfg.management.storage.storageClass;
          };
        };

        netbird-management-cm = {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata = {
            name = "netbird-management";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          data."management.tmpl.json" = managementConfigJson;
        };

        netbird-management-svc = {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            name = "netbird-management";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            type = "ClusterIP";
            selector."app.kubernetes.io/name" = "netbird-management";
            ports = [

              {
                name = "http";
                port = 80;
                targetPort = "http";
                protocol = "TCP";
                appProtocol = "kubernetes.io/h2c";
              }

              {
                name = "grpc";
                port = 33073;
                targetPort = "grpc";
                protocol = "TCP";
                appProtocol = "kubernetes.io/h2c";
              }
              {
                name = "metrics";
                port = 9090;
                targetPort = "metrics";
                protocol = "TCP";
              }
            ];
          };
        };

        netbird-management = {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            name = "netbird-management";
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
              "app.kubernetes.io/name" = "netbird-management";
            };
          };
          spec = {
            replicas = cfg.management.replicas;
            strategy.type = "Recreate";
            selector.matchLabels."app.kubernetes.io/name" = "netbird-management";
            template = {
              metadata = {
                labels = {
                  "app.kubernetes.io/name" = "netbird-management";
                  "app.kubernetes.io/managed-by" = "catallaxy";
                };

                annotations."catallaxy.io/management-config-hash" = builtins.substring 0 12 (
                  builtins.hashString "sha256" managementConfigJson
                );
              };
              spec = {
                serviceAccountName = "netbird-management";
                initContainers =
                  mkWaitForSecrets [

                    {
                      name = "relay-secret";
                      secret = "netbird-relay-secret";
                      key = "netbird-relay-secret-key";
                    }
                    {
                      name = "datastore-enc-key";
                      secret = "netbird-datastore-enc-key";
                      key = "key";
                    }
                  ]
                  ++ [
                    {

                      name = "configure";
                      image = cfg.images.wait.ref;
                      command = [
                        "sh"
                        "-c"
                      ];
                      args = [
                        ''
                          set -eu
                          RELAY=$(cat /etc/netbird-secrets/RELAY_AUTH_SECRET)
                          DSEK=$(cat /etc/netbird-secrets/DATASTORE_ENC_KEY)
                          sed -e "s#@RELAY_AUTH_SECRET@#$RELAY#g" \
                              -e "s#@DATASTORE_ENC_KEY@#$DSEK#g" \
                              /tmp/netbird/management.tmpl.json \
                              > /etc/netbird/management.json
                          cat /etc/netbird/management.json | head -20
                        ''
                      ];
                      volumeMounts = [
                        {
                          name = "config";
                          mountPath = "/etc/netbird";
                        }
                        {
                          name = "config-template";
                          mountPath = "/tmp/netbird";
                        }
                        {
                          name = "relay-secret";
                          mountPath = "/etc/netbird-secrets/RELAY_AUTH_SECRET";
                          subPath = "netbird-relay-secret-key";
                          readOnly = true;
                        }
                        {
                          name = "datastore-enc-key";
                          mountPath = "/etc/netbird-secrets/DATASTORE_ENC_KEY";
                          subPath = "key";
                          readOnly = true;
                        }
                      ];
                    }
                  ]

                  ++ lib.optional (idpIssuer != "") (
                    k8sHelpers.wait.mkWaitInitContainer {
                      name = "wait-for-oidc";
                      probe = {
                        kind = "http";
                        url = "${idpIssuer}/.well-known/openid-configuration";
                        expectedStatus = 200;
                        timeout = waitTimeoutStr;
                        interval = "${toString cfg.wait.intervalSeconds}s";
                        caBundleMount =
                          if hasCaBundle then
                            {
                              configMap = cfg.tls.caBundle.name;
                              key = cfg.tls.caBundle.key;
                              mountPath = "/etc/netbird-ca";

                              filename = "lab-ca.crt";
                            }
                          else
                            null;
                      };
                    }
                  );
                containers = [
                  {
                    name = "netbird-management";
                    image = cfg.images.management.ref;
                    imagePullPolicy = "IfNotPresent";
                    args = [
                      "--log-level"
                      "info"
                      "--log-file"
                      "console"
                      "--dns-domain"
                      cfg.domain
                    ];
                    env = optional hasCaBundle {

                      name = "SSL_CERT_DIR";
                      value = "/etc/ssl/certs:/etc/netbird-ca";
                    };
                    ports = [
                      {
                        name = "http";
                        containerPort = 80;
                        protocol = "TCP";
                      }
                      {
                        name = "grpc";
                        containerPort = 33073;
                        protocol = "TCP";
                      }
                      {
                        name = "metrics";
                        containerPort = 9090;
                        protocol = "TCP";
                      }
                    ];
                    volumeMounts = [
                      {
                        name = "config";
                        mountPath = "/etc/netbird";
                      }
                      {
                        name = "management";
                        mountPath = "/var/lib/netbird";
                      }
                    ]
                    ++ optional hasCaBundle {

                      name = k8sHelpers.wait.caBundleVolumeName;
                      mountPath = "/etc/netbird-ca";
                      readOnly = true;
                    };
                  }
                ];
                volumes = [
                  {
                    name = "config";
                    emptyDir.medium = "Memory";
                  }
                  {
                    name = "config-template";
                    configMap.name = "netbird-management";
                  }
                  {
                    name = "management";
                    persistentVolumeClaim.claimName = "netbird-management";
                  }
                  {
                    name = "relay-secret";
                    secret.secretName = "netbird-relay-secret";
                  }
                  {
                    name = "datastore-enc-key";
                    secret.secretName = "netbird-datastore-enc-key";
                  }
                ]
                ++ optional hasCaBundle {
                  name = k8sHelpers.wait.caBundleVolumeName;
                  configMap = {
                    name = cfg.tls.caBundle.name;
                    items = [
                      {
                        key = cfg.tls.caBundle.key;

                        path = "lab-ca.crt";
                      }
                    ];
                  };
                };
              };
            };
          };
        };
      };

      netbirdSignalResources = {
        netbird-signal-sa = {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = "netbird-signal";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
        };

        netbird-signal-svc = {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            name = "netbird-signal";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            type = "ClusterIP";
            selector."app.kubernetes.io/name" = "netbird-signal";
            ports = [

              {
                name = "http";
                port = signalPort;
                targetPort = "http";
                protocol = "TCP";
                appProtocol = "kubernetes.io/h2c";
              }

              {
                name = "grpc-compat";
                port = signalLegacyGrpcPort;
                targetPort = signalLegacyGrpcPort;
                protocol = "TCP";
                appProtocol = "kubernetes.io/h2c";
              }
              {
                name = "metrics";
                port = 9090;
                targetPort = "metrics";
                protocol = "TCP";
              }
            ];
          };
        };

        netbird-signal = {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            name = "netbird-signal";
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
              "app.kubernetes.io/name" = "netbird-signal";
            };
          };
          spec = {
            replicas = cfg.signal.replicas;
            selector.matchLabels."app.kubernetes.io/name" = "netbird-signal";
            template = {
              metadata.labels."app.kubernetes.io/name" = "netbird-signal";
              spec = {
                serviceAccountName = "netbird-signal";
                containers = [
                  {
                    name = "netbird-signal";
                    image = cfg.images.signal.ref;
                    imagePullPolicy = "IfNotPresent";
                    args = [
                      "--port"
                      (toString signalPort)
                      "--log-level"
                      "info"
                      "--log-file"
                      "console"
                    ];
                    ports = [
                      {
                        name = "http";
                        containerPort = signalPort;
                        protocol = "TCP";
                      }
                      {
                        name = "grpc-compat";
                        containerPort = signalLegacyGrpcPort;
                        protocol = "TCP";
                      }
                      {
                        name = "metrics";
                        containerPort = 9090;
                        protocol = "TCP";
                      }
                    ];
                    livenessProbe.tcpSocket.port = "http";
                    readinessProbe.tcpSocket.port = "http";
                  }
                ];
              };
            };
          };
        };
      };

      netbirdRelayResources = {
        netbird-relay-sa = {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = "netbird-relay";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
        };

        netbird-relay-svc = {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            name = "netbird-relay";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            type = "ClusterIP";
            selector."app.kubernetes.io/name" = "netbird-relay";
            ports = [
              {
                name = "http";
                port = 33080;
                targetPort = "ws";
                protocol = "TCP";
              }
              {
                name = "metrics";
                port = 9090;
                targetPort = "metrics";
                protocol = "TCP";
              }
            ];
          };
        };

        netbird-relay = {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            name = "netbird-relay";
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
              "app.kubernetes.io/name" = "netbird-relay";
            };
          };
          spec = {
            replicas = 1;
            selector.matchLabels."app.kubernetes.io/name" = "netbird-relay";
            template = {
              metadata.labels."app.kubernetes.io/name" = "netbird-relay";
              spec = {
                serviceAccountName = "netbird-relay";
                containers = [
                  {
                    name = "netbird-relay";
                    image = cfg.images.relay.ref;
                    imagePullPolicy = "IfNotPresent";
                    args = [
                      "--log-file"
                      "console"
                    ];
                    env = [
                      {
                        name = "NB_LOG_LEVEL";
                        value = "info";
                      }
                      {
                        name = "NB_LISTEN_ADDRESS";
                        value = ":33080";
                      }
                      {
                        name = "NB_EXPOSED_ADDRESS";
                        value = cfg.domain;
                      }
                      {
                        name = "NB_AUTH_SECRET";
                        valueFrom.secretKeyRef = {
                          name = "netbird-relay-secret";
                          key = "netbird-relay-secret-key";
                        };
                      }
                    ];
                    ports = [
                      {
                        name = "ws";
                        containerPort = 33080;
                        protocol = "TCP";
                      }
                      {
                        name = "metrics";
                        containerPort = 9090;
                        protocol = "TCP";
                      }
                    ];
                    livenessProbe.tcpSocket.port = "ws";
                    readinessProbe.tcpSocket.port = "ws";
                  }
                ];
              };
            };
          };
        };
      };

      bootstrapRbac = {
        netbird-bootstrap-sa = {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = "netbird-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
        };
        netbird-bootstrap-role = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "Role";
          metadata = {
            name = "netbird-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          rules = [
            {
              apiGroups = [ "" ];
              resources = [ "secrets" ];
              verbs = [
                "get"
                "create"
                "update"
                "patch"
              ];
            }

            {
              apiGroups = [ "kaniop.rs" ];
              resources = [ "kanidmoauth2clients" ];
              verbs = [
                "get"
                "list"
                "watch"
              ];
            }
          ];
        };
        netbird-bootstrap-rb = {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "RoleBinding";
          metadata = {
            name = "netbird-bootstrap";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "netbird-bootstrap";
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = "netbird-bootstrap";
              namespace = cfg.namespace;
            }
          ];
        };
      };

      catalLib = import ../../../../../lib/util/idempotent-job.nix { inherit lib; };

      netbirdBootstrapScript = builtins.readFile ./scripts/bootstrap.sh;

      netbirdBootstrapPodSpec = {
        serviceAccountName = "netbird-bootstrap";
        restartPolicy = "OnFailure";
        containers = [
          {
            name = "bootstrap";
            image = cfg.images.bootstrap.ref;
            env = [
              {
                name = "NB_NS";
                value = cfg.namespace;
              }
              {
                name = "NB_URL";
                value = "http://netbird-management.${cfg.namespace}.svc.cluster.local";
              }
              {
                name = "OAUTH2_CLIENT_NAME";
                value = idpClientId;
              }
              {
                name = "BOT_TOKEN_NS";
                value =
                  if idpMachineTokenRef != null && idpMachineTokenRef.namespace != null then
                    idpMachineTokenRef.namespace
                  else
                    cfg.namespace;
              }
              {
                name = "BOT_TOKEN_SECRET";
                value = if idpMachineTokenRef != null then idpMachineTokenRef.name else "";
              }
              {
                name = "BOT_TOKEN_KEY";
                value = if idpMachineTokenRef != null then idpMachineTokenRef.key else "token";
              }
              {
                name = "TOKEN_ENDPOINT";
                value = idpMachineTokenEndpoint;
              }
              {
                name = "OIDC_DISCOVERY";
                value = if idpIssuer != "" then "${idpIssuer}/.well-known/openid-configuration" else "";
              }
              {
                name = "OUT_SECRET";
                value = apiTokenSecretName;
              }
              {
                name = "OUT_KEY";
                value = cfg.operator.apiTokenSecretKey;
              }
              {

                name = "NB_JWT_SPNS_JSON";
                value = jwtDiscoverySpnsJson;
              }
              {
                name = "JWT_GROUP_UUIDS_SECRET";
                value = jwtGroupUuidsSecretName;
              }

              # These three used to be spliced into the script as Nix string
              # interpolations, which is why it could not live in a .sh file.
              # They are jq arguments now, so the script is a script.
              {
                name = "NB_LAZY_CONNECTIONS";
                value = if cfg.lazyConnections then "true" else "false";
              }
              {
                name = "NB_JWT_GROUPS_CLAIM";
                value = cfg.operator.jwtGroupsClaimName;
              }
              {
                name = "NB_JWT_ALLOW_GROUPS";
                value = builtins.toJSON cfg.operator.autoGroupsFromJwt;
              }
            ];
            command = [
              "bash"
              "-c"
            ];
            args = [ netbirdBootstrapScript ];
            volumeMounts = optional hasCaBundle {
              name = "lab-ca";
              mountPath = "/etc/ssl/certs/lab-ca.crt";
              subPath = cfg.tls.caBundle.key;
              readOnly = true;
            };
          }
        ];
        volumes = optional hasCaBundle {
          name = "lab-ca";
          configMap.name = cfg.tls.caBundle.name;
        };
      };

      botTokenNs =
        if idpMachineTokenRef != null then
          (if idpMachineTokenRef.namespace != null then idpMachineTokenRef.namespace else cfg.namespace)
        else
          null;

      botTokenRbac =
        if (idpMachineTokenRef != null && botTokenNs != cfg.namespace) then
          {
            netbird-bootstrap-bot-token-reader-role = {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "Role";
              metadata = {
                name = "netbird-bootstrap-bot-token-reader";
                namespace = botTokenNs;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              rules = [
                {
                  apiGroups = [ "" ];
                  resources = [ "secrets" ];
                  resourceNames = [ idpMachineTokenRef.name ];
                  verbs = [
                    "get"
                    "list"
                    "watch"
                  ];
                }
              ];
            };
            netbird-bootstrap-bot-token-reader-rb = {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "RoleBinding";
              metadata = {
                name = "netbird-bootstrap-bot-token-reader";
                namespace = botTokenNs;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "Role";
                name = "netbird-bootstrap-bot-token-reader";
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = "netbird-bootstrap";
                  namespace = cfg.namespace;
                }
              ];
            };
          }
        else
          { };

      netbirdBootstrapJobResources =
        if idpMachineTokenRef != null then
          (catalLib.mkIdempotentJob {
            name = "netbird-bootstrap";
            namespace = cfg.namespace;
            contentInputs = {
              issuer = idpIssuer;
              clientID = idpClientId;
              tokenEndpoint = idpMachineTokenEndpoint;
              botTokenName = idpMachineTokenRef.name;
              botTokenNs = botTokenNs;
              botTokenKey = idpMachineTokenRef.key;
              netbirdUrl = "http://netbird-management.${cfg.namespace}.svc.cluster.local";
              outSecret = apiTokenSecretName;
              outKey = cfg.operator.apiTokenSecretKey;
            };
            behaviourVersion = 1;
            podSpec = netbirdBootstrapPodSpec;
          }).resources
          // botTokenRbac
        else
          { };

      mkResourcesJson =
        netName: resources:
        builtins.toJSON (
          lib.mapAttrsToList (n: r: {
            name = "${netName}-${n}";
            inherit (r)
              address
              sourceGroups
              description
              enabled
              ;
          }) resources
        );

      netbirdRoutingScript = builtins.readFile ./scripts/routing.sh;

      mkRoutingPodSpec = netName: net: {
        serviceAccountName = "netbird-bootstrap";
        restartPolicy = "OnFailure";
        containers = [
          {
            name = "routing";
            image = cfg.images.bootstrap.ref;
            env = [
              {
                name = "NB_NS";
                value = cfg.namespace;
              }
              {
                name = "NB_URL";
                value = "http://netbird-management.${cfg.namespace}.svc.cluster.local";
              }
              {
                name = "PAT_SECRET";
                value = apiTokenSecretName;
              }
              {
                name = "PAT_KEY";
                value = cfg.operator.apiTokenSecretKey;
              }
              {
                name = "NB_NETWORK_NAME";
                value = netName;
              }
              {

                name = "NB_RESOURCES_JSON";
                value = mkResourcesJson netName net.resources;
              }
              {
                name = "DNS_DOMAINS";
                value = lib.concatStringsSep " " cfg.routing.dnsDomains;
              }
              {
                name = "RESOLVER_IP";
                value = cfg.routing.resolverIP;
              }
              {
                name = "SOURCE_GROUPS";
                value = lib.concatStringsSep " " cfg.routing.sourceGroups;
              }
              {
                name = "ROUTER_GROUP";
                value = net.routerGroup;
              }
              {

                name = "JWT_GROUP_UUIDS_SECRET";
                value = jwtGroupUuidsSecretName;
              }
            ];
            command = [
              "bash"
              "-c"
            ];
            args = [ netbirdRoutingScript ];
          }
        ];
      };

      mkRoutingCronJob = netName: net: {
        "netbird-routing-cron-${netName}" = {
          apiVersion = "batch/v1";
          kind = "CronJob";
          metadata = {
            name = "netbird-routing-${netName}";
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
              "app.kubernetes.io/component" = "netbird-routing";
            };
          };
          spec = {
            schedule = "*/2 * * * *";
            concurrencyPolicy = "Forbid";
            successfulJobsHistoryLimit = 1;
            failedJobsHistoryLimit = 3;
            startingDeadlineSeconds = 60;
            jobTemplate = {
              spec = {
                backoffLimit = 2;
                template = {
                  metadata.labels = {
                    "app.kubernetes.io/managed-by" = "catallaxy";
                    "app.kubernetes.io/component" = "netbird-routing";
                  };
                  spec = (mkRoutingPodSpec netName net) // {
                    restartPolicy = "Never";
                  };
                };
              };
            };
          };
        };
      };

      netbirdRoutingJobResources =
        if cfg.routing.enable then
          lib.foldl' (
            acc: netName:
            let
              net = cfg.routing.networks.${netName};
            in
            acc // (mkRoutingJob netName net).resources // (mkRoutingCronJob netName net)
          ) { } (lib.attrNames cfg.routing.networks)
        else
          { };

      # Routing is one Job per network, and a label selector cannot say "any
      # of these hashes". So every Job of a given render carries the same
      # generation, derived from the same configuration its individual hashes
      # come from: change anything a routing Job is told and this moves too.
      # It is what lets the readyProbe wait on this render's Jobs rather than
      # on every Job the floe has ever produced.
      routingGeneration = catalLib.hashContent {
        inherit (cfg.routing) networks dnsDomains resolverIP;
      };

      mkRoutingJob =
        netName: net:
        catalLib.mkIdempotentJob {
          name = "netbird-routing-${netName}";
          namespace = cfg.namespace;
          extraLabels = {
            "catallaxy.io/netbird-routing" = "true";
            "catallaxy.io/netbird-routing-generation" = routingGeneration;
          };
          contentInputs = {
            inherit netName;
            inherit (cfg.routing) dnsDomains resolverIP;
            inherit (net) routerGroup;

            resources = mkResourcesJson netName net.resources;
          };
          behaviourVersion = 1;
          podSpec = mkRoutingPodSpec netName net;
        };

      netbirdAdminReconcilerScript = builtins.readFile ./scripts/admin-reconciler.sh;

      netbirdAdminReconcilerContainer = {
        name = "reconciler";
        image = cfg.images.bootstrap.ref;
        env = [
          {
            name = "NB_NS";
            value = cfg.namespace;
          }
          {
            name = "NB_URL";
            value = "http://netbird-management.${cfg.namespace}.svc.cluster.local";
          }
          {
            name = "PAT_SECRET";
            value = apiTokenSecretName;
          }
          {
            name = "PAT_KEY";
            value = cfg.operator.apiTokenSecretKey;
          }
          {
            name = "NB_ADMIN_GROUPS_JSON";
            value = adminGroupsJson;
          }
          {
            name = "JWT_GROUP_UUIDS_SECRET";
            value = jwtGroupUuidsSecretName;
          }
        ];
        command = [
          "bash"
          "-c"
        ];
        args = [ netbirdAdminReconcilerScript ];
      };

      netbirdAdminReconcilerPodSpec = {
        serviceAccountName = "netbird-bootstrap";
        restartPolicy = "OnFailure";
        containers = [ netbirdAdminReconcilerContainer ];
      };

      netbirdAdminReconcilerCronJob = {
        netbird-admin-reconciler-cron = {
          apiVersion = "batch/v1";
          kind = "CronJob";
          metadata = {
            name = "netbird-admin-reconciler";
            namespace = cfg.namespace;
            labels = {
              "app.kubernetes.io/managed-by" = "catallaxy";
              "app.kubernetes.io/component" = "netbird-admin-reconciler";
            };
          };
          spec = {
            schedule = "*/2 * * * *";
            concurrencyPolicy = "Forbid";
            successfulJobsHistoryLimit = 1;
            failedJobsHistoryLimit = 3;
            startingDeadlineSeconds = 60;
            jobTemplate = {
              spec = {
                backoffLimit = 2;
                template = {
                  metadata.labels = {
                    "app.kubernetes.io/managed-by" = "catallaxy";
                    "app.kubernetes.io/component" = "netbird-admin-reconciler";
                  };
                  spec = netbirdAdminReconcilerPodSpec // {

                    restartPolicy = "Never";
                  };
                };
              };
            };
          };
        };
      };

      netbirdAdminReconcilerJobResources =
        if cfg.operator.enable then
          (catalLib.mkIdempotentJob {
            name = "netbird-admin-reconciler";
            namespace = cfg.namespace;
            contentInputs = {
              adminGroups = adminGroupsJson;
            };
            behaviourVersion = 1;
            podSpec = netbirdAdminReconcilerPodSpec;
          }).resources
          // netbirdAdminReconcilerCronJob
        else
          { };

      netbirdKubeContext = config.cluster.ref.kubeContext;
      netbirdMgmtUrl = "https://${cfg.domain}";

      netbirdClient = import ./client.nix {
        inherit lib pkgs;
        client = cfg.client;
      };

      mkNetbirdOpsScript =
        {
          name,
          runtimeInputs ? [ ],
          text,
        }:
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs =
            runtimeInputs
            ++ [
              pkgs.kubectl
              pkgs.coreutils
            ]
            ++ lib.optional pkgs.stdenv.isLinux pkgs.systemd;

          text = ''
            set -eu
            export KUBE_CONTEXT="''${KUBECONTEXT:-${netbirdKubeContext}}"
            export NB_NS="${cfg.namespace}"
            export NB_URL="${netbirdMgmtUrl}"
            export NB_HOST="${cfg.domain}"
            export NB_CLI="${netbirdClient.cli}/bin/${cfg.client.serviceName}"
            export NB_DAEMON_UP="${netbirdClient.daemon}/bin/${cfg.client.serviceName}-daemon"
            export NB_DAEMON_STOP="${netbirdClient.stop}/bin/${cfg.client.serviceName}-stop"
            ${text}
          '';
        };

      netbirdOpsScripts = {

        login = mkNetbirdOpsScript {
          name = "login";

          text = ''
            if "$NB_CLI" status 2>/dev/null | grep -q "Management: Connected"; then
              echo ">>> Already on the mesh. Management: Connected"
              exit 0
            fi

            "$NB_DAEMON_UP"

            echo ">>> Joining mesh at $NB_URL (SSO via kanidm)"

            EXPECTED_CONFIG_HASH="${
              builtins.substring 0 12 (builtins.hashString "sha256" managementConfigJson)
            }"

            pf_ok=true
            pf_fix() {
              echo ">>> preflight: $1: FAIL" >&2
              echo ">>> fix: $2" >&2
              pf_ok=false
            }
            pf_pass() {
              echo ">>> preflight: $1: ok"
            }

            EXPECTED_MGMT_IMAGE="${cfg.images.management.ref}"
            server_image=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" get deploy netbird-management -o jsonpath='{.spec.template.spec.containers[?(@.name=="netbird-management")].image}' 2>/dev/null || true)
            if [ -z "$server_image" ]; then
              pf_fix "management image matches source" "could not read the live image; check kubectl access to $KUBE_CONTEXT"
            elif [ "$server_image" != "$EXPECTED_MGMT_IMAGE" ]; then
              pf_fix "management image matches source" "live=$server_image expected=$EXPECTED_MGMT_IMAGE. Run 'cata lab up' to reconcile the Deployment"
            else
              pf_pass "management image matches source ($server_image)"
            fi

            cli_ver=$("$NB_CLI" version 2>/dev/null | head -1 | awk '{print $NF}' | sed 's/^v//' || true)
            if [ -n "$cli_ver" ] && [ "$cli_ver" != "${cfg.client.package.version or ""}" ]; then
              pf_fix "client wrapper is current" "wrapper reports $cli_ver, this tree pins ${
                cfg.client.package.version or "?"
              }. Rebuild the lab package"
            else
              pf_pass "client wrapper is current ($cli_ver)"
            fi

            cm_null=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" get cm netbird-management -o 'jsonpath={.data.management\.tmpl\.json}' 2>/dev/null | grep -c '"DeviceAuthorizationFlow": *null' || true)
            if [ "$cm_null" = "0" ]; then
              pf_fix "configmap has DeviceAuthorizationFlow:null" "ConfigMap is stale. Re-run 'cata --flake .#<lab> lab up' so the netbird-management CM re-applies"
            else
              pf_pass "configmap has DeviceAuthorizationFlow:null"
            fi

            live_hash=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" get deploy netbird-management -o 'jsonpath={.spec.template.metadata.annotations.catallaxy\.io/management-config-hash}' 2>/dev/null || true)
            if [ -z "$live_hash" ]; then
              pf_fix "pod-template config hash present" "Deployment lacks catallaxy.io/management-config-hash annotation. Run 'cata lab up' with this framework version"
            elif [ "$live_hash" != "$EXPECTED_CONFIG_HASH" ]; then
              pf_fix "pod-template config hash matches source" "live=$live_hash expected=$EXPECTED_CONFIG_HASH. Run 'cata lab up' to reconcile the Deployment"
            else
              pf_pass "pod-template config hash ($live_hash)"
            fi

            pod_null=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" exec deploy/netbird-management -c netbird-management -- grep -c '"DeviceAuthorizationFlow": *null' /etc/netbird/management.json 2>/dev/null || echo 0)
            if [ "$pod_null" = "0" ]; then
              pf_fix "pod loaded DeviceAuthorizationFlow:null" "Pod is still running pre-fix config. Force a roll: kubectl --context $KUBE_CONTEXT -n $NB_NS rollout restart deploy/netbird-management"
            else
              pf_pass "pod loaded DeviceAuthorizationFlow:null"
            fi

            if kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" wait --for=condition=available --timeout=5s deploy/netbird-management >/dev/null 2>&1; then
              pf_pass "netbird-management deployment available"
            else
              pf_fix "netbird-management deployment available" "kubectl wait timed out. Inspect: kubectl --context $KUBE_CONTEXT -n $NB_NS describe deploy/netbird-management"
            fi

            if [ "$pf_ok" != "true" ]; then
              echo ">>> preflight failed. See FAIL lines above. Fixing the reported invariant is a prerequisite to a successful 'netbird up'." >&2
              exit 1
            fi
            echo ">>> preflight: all invariants ok"

            cat <<'BANNER'
            >>> Preparing browser-based SSO login for netbird.
            >>> Netbird will print a URL below. Open it in a browser ON THIS MACHINE.
            >>> After you complete the kanidm login, the browser redirects to the
            >>> redirect_uri in that URL, which is one of ${
              lib.concatMapStringsSep ", " toString cfg.client.callbackPorts
            }
            >>> on localhost; netbird takes the first of those that is free.
            >>> Netbird catches that callback and brings the mesh up.
            >>>
            >>> If your terminal is on a remote host (SSH), the browser callback
            >>> won't reach netbird's loopback listener. Either run this from
            >>> your local machine, or SSH forwarding the port the URL names:
            >>>   ssh ${
              lib.concatMapStringsSep " " (p: "-L ${toString p}:localhost:${toString p}") cfg.client.callbackPorts
            } <user>@<host>
            BANNER

            UP_EXIT=0

            if timeout -k 5 5 "$NB_CLI" status 2>&1 \
              | grep -q "Management: Connected"; then
              echo ">>> Already joined. Management: Connected"
              exit 0
            fi

            JOIN_STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S')

            callback_landed() {
              ${
                if pkgs.stdenv.isLinux then
                  ''journalctl -u ${cfg.client.serviceName}.service --since "$JOIN_STARTED_AT" --no-pager 2>/dev/null''
                else
                  "tail -n 500 ${cfg.client.logFile} 2>/dev/null"
              } | grep -q 'successfully registered on Management Service'
            }

            (
              start=$(date +%s)
              phase=browser
              tick=0
              while :; do
                sleep 5
                tick=$(( tick + 1 ))
                elapsed=$(( $(date +%s) - start ))

                if [ "$phase" = browser ] && callback_landed; then
                  phase=mesh
                  echo "" >&2
                  echo ">>> Login accepted. The callback reached the daemon and the peer" >&2
                  echo ">>> is registered. Nothing further is needed from you." >&2
                  echo ">>> Bringing the mesh up. \`netbird up\` may still report a" >&2
                  echo ">>> deadline here; it stops watching before a cold daemon" >&2
                  echo ">>> finishes, and the daemon is what decides." >&2
                  echo "" >&2
                  tick=0
                fi

                [ $(( tick % 4 )) -eq 0 ] || continue

                if [ "$phase" = browser ]; then
                  echo ">>> Waiting for you to finish the browser login… ''${elapsed}s elapsed (window 300s)" >&2
                else
                  echo ">>> Bringing the mesh up… ''${elapsed}s elapsed since the login started" >&2
                fi
              done
            ) &
            HEARTBEAT_PID=$!
            UP_STDERR=$(mktemp)
            # shellcheck disable=SC2064
            trap "kill $HEARTBEAT_PID 2>/dev/null || true; rm -f $UP_STDERR" EXIT

            lab_profile_ids() {
              "$NB_CLI" profile list --show-id 2>/dev/null \
                | awk -v n="${cfg.client.profileName}" '$2 == n { print $1 }'
            }

            PROFILE_IDS=$(lab_profile_ids)
            if [ -z "$PROFILE_IDS" ]; then
              "$NB_CLI" profile add "${cfg.client.profileName}" >/dev/null 2>&1 || true
              PROFILE_IDS=$(lab_profile_ids)
            fi

            PROFILE_ID=$(printf '%s\n' "$PROFILE_IDS" | head -1)
            if [ -z "$PROFILE_ID" ] || ! "$NB_CLI" profile select "$PROFILE_ID" >/dev/null 2>&1; then
              echo "!!! could not select netbird profile '${cfg.client.profileName}'." >&2
              echo "!!! \`netbird up\` would act on whichever profile is active, which" >&2
              echo "!!! may belong to another lab. Refusing to continue." >&2
              exit 1
            fi

            printf '%s\n' "$PROFILE_IDS" | tail -n +2 | while read -r dup; do
              [ -n "$dup" ] || continue
              "$NB_CLI" profile remove "$dup" >/dev/null 2>&1 || true
            done

            "$NB_CLI" up --management-url "$NB_URL" ${
              lib.concatStringsSep " " (
                [
                  "--interface-name ${cfg.client.interfaceName}"
                  "--wireguard-port ${toString cfg.client.wireguardPort}"
                ]
                ++ lib.optional (
                  cfg.client.dnsResolverAddress != ""
                ) "--dns-resolver-address ${cfg.client.dnsResolverAddress}"
                ++ cfg.client.extraUpArgs
              )
            } 2>"$UP_STDERR" || UP_EXIT=$?

            kill $HEARTBEAT_PID 2>/dev/null || true
            wait $HEARTBEAT_PID 2>/dev/null || true

            if [ "$UP_EXIT" -eq 0 ]; then
              echo ">>> Login accepted. Confirming with the daemon…" >&2
              STATUS=$(timeout -k 5 ${toString cfg.client.statusTimeoutSeconds} "$NB_CLI" status 2>&1 || true)
              if echo "$STATUS" | grep -q "Management: Connected"; then
                echo ">>> Mesh joined. Management: Connected"
              else
                echo ">>> Mesh joined. The daemon did not answer \`status\` within" >&2
                echo ">>> ${toString cfg.client.statusTimeoutSeconds}s, which it often does not straight after a" >&2
                echo ">>> login; \`netbird up\` succeeded, so the join stands. To look:" >&2
                echo ">>>   journalctl -u ${cfg.client.serviceName}.service" >&2
              fi
              exit 0
            fi

            echo "" >&2
            echo ">>> Login done; waiting for the daemon to finish bringing the mesh up." >&2

            grace_deadline=$(( $(date +%s) + ${toString cfg.client.joinGraceSeconds} ))
            while [ "$(date +%s)" -lt "$grace_deadline" ]; do
              if timeout -k 5 10 "$NB_CLI" status 2>/dev/null \
                | grep -q "Management: Connected"; then
                echo ">>> Mesh joined. Management: Connected"
                exit 0
              fi
              sleep 5
            done

            echo ""
            echo "!!! netbird up exited $UP_EXIT. This lab is not on the mesh."
            echo "--- netbird up ---"
            cat "$UP_STDERR" >&2 || true
            echo "!!! The daemon's own account of the login follows. Read it before"
            echo "!!! changing anything: 'context deadline exceeded' means no callback"
            echo "!!! reached the flow, which is a different fault from one that"
            echo "!!! reached it and failed."
            echo "--- ${cfg.client.serviceName} daemon log ---"
            ${
              if pkgs.stdenv.isLinux then
                "journalctl -u ${cfg.client.serviceName}.service -n 40 --no-pager 2>&1 || true"
              else
                "tail -n 40 ${cfg.client.logFile} 2>&1 || true"
            }
            echo "---"
            echo "!!! Re-run this step to get a fresh login URL. Only one login flow"
            echo "!!! can be in flight per daemon, so the URL is not re-issued"
            echo "!!! underneath you while you are completing it."
            ${lib.optionalString (cfg.client.logLevel == "info") ''
              echo "!!! For a diagnosable log, set floes.netbird.client.logLevel = \"debug\"."
            ''}
            exit 1
          '';
        };

        status = mkNetbirdOpsScript {
          name = "status";
          text = ''
            if [ ! -S "${lib.removePrefix "unix://" cfg.client.daemonAddr}" ]; then
              echo ">>> This lab's netbird daemon is not running."
              echo ">>> Join with: cata lab ops -- netbird login"
              exit 1
            fi
            exec "$NB_CLI" status "$@"
          '';
        };

        logout = mkNetbirdOpsScript {
          name = "logout";

          text = ''
            nb() { timeout -k 5 ${toString cfg.client.statusTimeoutSeconds} "$NB_CLI" "$@"; }

            (
              nb down || true
              nb profile select default >/dev/null 2>&1 || true
              ids=$(nb profile list --show-id 2>/dev/null \
                | awk -v n="${cfg.client.profileName}" '$2 == n { print $1 }' || true)
              printf '%s\n' "$ids" | while read -r id; do
                [ -n "$id" ] || continue
                nb profile remove "$id" >/dev/null 2>&1 || true
              done
              echo ">>> Released netbird profile ${cfg.client.profileName}"
            ) || echo ">>> Could not reach the daemon to release its profile; stopping it anyway" >&2

            "$NB_DAEMON_STOP"
            echo ">>> Left the lab mesh and stopped its daemon"
          '';
        };

        peers = mkNetbirdOpsScript {
          name = "peers";
          runtimeInputs = with pkgs; [
            curl
            jq
          ];
          text = ''
            PAT=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" \
              get secret ${apiTokenSecretName} \
              -o jsonpath='{.data.${cfg.operator.apiTokenSecretKey}}' 2>/dev/null | base64 -d || true)
            if [ -z "$PAT" ]; then
              echo "Operator PAT Secret $NB_NS/${apiTokenSecretName} is empty; bootstrap incomplete." >&2
              exit 1
            fi
            curl -sk -H "Authorization: Token $PAT" "$NB_URL/api/peers" | jq .
          '';
        };

        routes = mkNetbirdOpsScript {
          name = "routes";
          runtimeInputs = with pkgs; [
            curl
            jq
          ];
          text = ''
            PAT=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" \
              get secret ${apiTokenSecretName} \
              -o jsonpath='{.data.${cfg.operator.apiTokenSecretKey}}' 2>/dev/null | base64 -d || true)
            if [ -z "$PAT" ]; then
              echo "Operator PAT Secret $NB_NS/${apiTokenSecretName} is empty; bootstrap incomplete." >&2
              exit 1
            fi
            curl -sk -H "Authorization: Token $PAT" "$NB_URL/api/routes" | jq .
          '';
        };

        check-config = mkNetbirdOpsScript {
          name = "check-config";
          runtimeInputs = with pkgs; [ jq ];
          text = ''
            ISSUER="${idpIssuer}"
            CLIENT_ID="${idpClientId}"
            BOT_TOKEN_NAME="${if idpMachineTokenRef != null then idpMachineTokenRef.name else ""}"
            BOT_TOKEN_NS="${
              if idpMachineTokenRef != null && idpMachineTokenRef.namespace != null then
                idpMachineTokenRef.namespace
              else
                cfg.namespace
            }"
            BOT_TOKEN_KEY="${if idpMachineTokenRef != null then idpMachineTokenRef.key else ""}"
            CA_CM="${if hasCaBundle then cfg.tls.caBundle.name else ""}"
            CA_KEY="${if hasCaBundle then cfg.tls.caBundle.key else "ca.crt"}"

            printf 'netbird preflight for lab %s (ctx=%s, ns=%s)\n\n' \
              "${cfg.domain}" "$KUBE_CONTEXT" "$NB_NS"

            BOT_TOKEN_VAL=$(kubectl --context "$KUBE_CONTEXT" -n "$BOT_TOKEN_NS" \
              get secret "$BOT_TOKEN_NAME" \
              -o jsonpath="{.data.$BOT_TOKEN_KEY}" 2>/dev/null | base64 -d || true)


            printf '  bot token .......... '
            if [ -n "$BOT_TOKEN_VAL" ]; then
              printf 'OK  (%s/%s[%s], %d bytes)\n' \
                "$BOT_TOKEN_NS" "$BOT_TOKEN_NAME" "$BOT_TOKEN_KEY" ''${#BOT_TOKEN_VAL}
            else
              printf 'FAIL\n    → Secret %s/%s[%s] is empty or missing.\n' \
                "$BOT_TOKEN_NS" "$BOT_TOKEN_NAME" "$BOT_TOKEN_KEY"
            fi

            PROBE_POD="netbird-check-config-$$"
            CA_MOUNT=""
            CA_VOL=""
            CACERT_ARG=""
            if [ -n "$CA_CM" ]; then
              CA_MOUNT=',{"name":"ca","mountPath":"/etc/netbird-ca","readOnly":true}'
              CA_VOL=',{"name":"ca","configMap":{"name":"'"$CA_CM"'","items":[{"key":"'"$CA_KEY"'","path":"lab-ca.crt"}]}}'
              CACERT_ARG="--cacert /etc/netbird-ca/lab-ca.crt"
            fi

            printf '  OIDC discovery ..... '
            DISC=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" run "$PROBE_POD" \
              --image="${cfg.images.bootstrap.ref}" \
              --restart=Never --rm -i --quiet \
              --overrides='{"spec":{"containers":[{"name":"probe","image":"${cfg.images.bootstrap.ref}","command":["sh","-c","curl -s '"$CACERT_ARG"' -o /tmp/d -w %{http_code} \"'"$ISSUER"'/.well-known/openid-configuration\" && cat /tmp/d"],"volumeMounts":[{"name":"tmp","mountPath":"/tmp"}'"$CA_MOUNT"']}],"volumes":[{"name":"tmp","emptyDir":{}}'"$CA_VOL"']}}' \
              -- sh -c 'true' 2>/dev/null || true)
            HTTP=$(printf '%s' "$DISC" | tail -c 3)
            BODY=$(printf '%s' "$DISC" | head -c -3)
            if [ "$HTTP" = "200" ]; then
              TOKEN_EP=$(printf '%s' "$BODY" | jq -r '.token_endpoint // empty')
              printf 'OK  (HTTP 200, token_endpoint=%s)\n' "$TOKEN_EP"
            else
              printf 'FAIL (HTTP %s)\n' "$HTTP"
              printf '    → verify idp.issuer resolves and the kanidm OAuth2Client "%s" exists.\n' "$CLIENT_ID"
              TOKEN_EP=""
            fi

            printf '  token exchange ..... '
            if [ -z "$TOKEN_EP" ] || [ -z "$BOT_TOKEN_VAL" ]; then
              printf 'skipped (prior step failed)\n'
            else
              # shellcheck disable=SC2016
              EXCH=$(kubectl --context "$KUBE_CONTEXT" -n "$NB_NS" run "$PROBE_POD-x" \
                --image="${cfg.images.bootstrap.ref}" \
                --restart=Never --rm -i --quiet \
                --env=TOKEN_EP="$TOKEN_EP" \
                --env=CLIENT_ID="$CLIENT_ID" \
                --env=SUBJECT_TOKEN="$BOT_TOKEN_VAL" \
                --overrides='{"spec":{"containers":[{"name":"probe","image":"${cfg.images.bootstrap.ref}","command":["sh","-c","curl -s '"$CACERT_ARG"' -o /tmp/r -w %{http_code} -X POST \"$TOKEN_EP\" -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange -d client_id=\"$CLIENT_ID\" -d subject_token=\"$SUBJECT_TOKEN\" -d subject_token_type=urn:ietf:params:oauth:token-type:access_token && cat /tmp/r"],"volumeMounts":[{"name":"tmp","mountPath":"/tmp"}'"$CA_MOUNT"']}],"volumes":[{"name":"tmp","emptyDir":{}}'"$CA_VOL"']}}' \
                -- sh -c 'true' 2>/dev/null || true)
              XHTTP=$(printf '%s' "$EXCH" | tail -c 3)
              if [ "$XHTTP" = "200" ]; then
                printf 'OK  (HTTP 200)\n'
              else
                printf 'FAIL (HTTP %s)\n' "$XHTTP"
                printf '    → verify kanidm OAuth2Client "%s" has grant_type=token-exchange enabled.\n' "$CLIENT_ID"
                printf '    → verify the bot service-account is a member of the OAuth2Client scope-map groups.\n'
              fi
            fi

            echo ""
            echo "Preflight complete. Fix any FAIL rows before running 'cata lab up'."
          '';
        };
      };

      hasClientSecretRef = idpMachineTokenRef != null;
      isFqdn =
        s: builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+" s != null;

      controlPlaneRequires =
        map
          (req: {
            assertion = !cfg.management.enable || (config.floes.${req} or { }).enable or false;
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
    lib.mkMerge [
      {
        assertions = netbirdAssertions;

        warnings = lib.optional (cfg.versionCheck && !serverTagComparable) ''
          netbird: `managementImage` is pinned to "${serverTag}", which carries no
          comparable version, so the client↔server version check cannot run. A
          client/server skew here fails by hanging during registration rather
          than erroring. Pin a `<major>.<minor>.<patch>` tag to get the check back.
        '';

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

      (mkIf (cfg.enable && cfg.operator.enable && cfg.operator.crds != null) {
        floes.netbird.network = {
          declared = true;

          egress.internet.ports = [ 443 ];
        };

        floes.netbird.imagesComplete = true;

        floes.netbird.images.operator = {
          registry = "ghcr.io";
          repository = "netbirdio/netbird-operator";
          tag = "v0.7.0";
        };

        bundles.netbird-operator-crds = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };
          yamls = [ cfg.operator.crds ];
          provides = [ "netbird/operator-crds/established" ];
        };
      })

      (mkIf (cfg.enable && cfg.management.enable) {
        ops.netbird.login = {

          description = "Join the lab's Netbird mesh (browser SSO via kanidm)";
          package = netbirdOpsScripts.login;
        };
        ops.netbird.logout = {
          description = "Leave the lab's Netbird mesh and stop its daemon";
          package = netbirdOpsScripts.logout;
        };
        ops.netbird.status = {
          description = "Show this lab's netbird client status (not your own daemon's)";
          package = netbirdOpsScripts.status;
        };
        ops.netbird.peers = {
          description = "List peers registered with the lab's Netbird management server";
          package = netbirdOpsScripts.peers;
        };
        ops.netbird.routes = {
          description = "List routes registered with the lab's Netbird management server";
          package = netbirdOpsScripts.routes;
        };
        ops.netbird.check-config = {
          description = "Preflight: validate OIDC wiring against the live IdP from inside the netbird namespace";
          package = netbirdOpsScripts.check-config;
        };
      })

      (mkIf (cfg.enable && cfg.management.enable) {
        # Both are read back as bytes rather than as strings: the datastore
        # key is base64 of a 32-byte AES key, and the relay secret keys an
        # HMAC. base64 encoding satisfies either reading.
        secrets.generate = {
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

        bundles.netbird-prechart = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };
          resources = bootstrapRbac;
          createNamespaces = [ cfg.namespace ];

          provides = [ "netbird/prechart/ready" ];
        };
      })

      (mkIf (cfg.enable && cfg.management.enable) {
        bundles.netbird = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };
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
          ++ refs.needs peers.cert-manager.issuance "webhookReady"
          ++ refs.needs peers.gateway.routing "publicReady"

          ++ lib.optional (hasCaBundle && cfg.tls.caBundle.readyToken != null) cfg.tls.caBundle.readyToken;

          after = refs.orderAfter peers.kanidm.identity "instanceReady";
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

      (mkIf (cfg.enable && cfg.management.enable && idpMachineTokenRef != null) {
        bundles.netbird-bootstrap = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };
          resources = netbirdBootstrapJobResources;

          requires = [

            "netbird/prechart/ready"

            "netbird/management/ready"
          ]

          ++ refs.needs peers.cert-manager.issuance "webhookReady";

          after = [
            "optional:provides:coredns/lab-dns/ready"
          ]
          ++ refs.orderAfter peers.kanidm.identity "provisioningReady";
          provides = [ "netbird/api-key/ready" ];
          readyProbe = {
            kind = "jsonpath";
            resource = "secret/${apiTokenSecretName}";
            namespace = cfg.namespace;
            jsonpath = "{.data.${cfg.operator.apiTokenSecretKey}}";
            timeout = "10m";
          };
        };
      })

      (mkIf (cfg.enable && cfg.routing.enable && cfg.operator.enable) {
        bundles.netbird-routing = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };
          resources = netbirdRoutingJobResources;

          requires = [
            "netbird/prechart/ready"
            "netbird/management/ready"

            "netbird/api-key/ready"

            "netbird/setup-keys/ready"
          ];

          provides = [ "netbird/routing/ready" ];

          readyProbe = lib.mkIf (cfg.routing.networks != { }) {
            kind = "kubectl-wait";
            args = [
              "--for=condition=complete"
              "job"
              "-l"
              "catallaxy.io/netbird-routing=true,catallaxy.io/netbird-routing-generation=${routingGeneration}"
              "-n"
              cfg.namespace
              "--timeout=5m"
            ];
          };
        };
      })

      (mkIf (cfg.enable && cfg.operator.enable) {
        bundles.netbird-admin-reconciler = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };
          resources = netbirdAdminReconcilerJobResources;

          requires = [
            "netbird/prechart/ready"
            "netbird/management/ready"
            "netbird/api-key/ready"
          ];
        };
      })

      (mkIf (cfg.enable && cfg.operator.enable) {
        bundles.netbird-operator = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };

          requires = [

            "netbird/api-key/ready"
            "netbird/operator-crds/established"
          ]

          ++ refs.needs peers.cert-manager.issuance "webhookReady";
          provides = [ "netbird/operator/ready" ];
          readyProbe = {
            kind = "condition";
            resource = "deployment/netbird-operator";
            namespace = cfg.namespace;
            condition = "Available";
            timeout = "10m";
          };

          helmCharts.netbird-operator = {
            chart = cfg.operator.chart;
            releaseName = "netbird-operator";
            namespace = cfg.namespace;
            createNamespace = true;
            values = {

              managementURL =
                if cfg.operator.managementUrl != "" then
                  cfg.operator.managementUrl
                else
                  "http://netbird-management.${cfg.namespace}.svc.cluster.local";
              netbirdAPI.keyFromSecret = {
                name = apiTokenSecretName;
                key = cfg.operator.apiTokenSecretKey;
              };

              webhook.failurePolicy = "Ignore";
            };
          };
        };
      })

      (mkIf (cfg.enable && cfg.operator.enable) {
        bundles.netbird-state = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };
          resources = groupResources // setupKeyResources;

          requires = [ "netbird/operator/ready" ];
          provides = [ "netbird/setup-keys/ready" ];

          readyProbe =
            if cfg.agent.enable && cfg.agent.setupKeyRef.name != "" then
              {
                kind = "jsonpath";
                resource = "secret/${cfg.agent.setupKeyRef.name}";
                namespace = cfg.agent.namespace;
                jsonpath = "{.data.${cfg.agent.setupKeyRef.key}}";
                timeout = "10m";
              }
            else
              null;
        };
      })

      (mkIf cfg.agent.enable {
        steps.netbird-agent-peer-cleanup = {
          kind = "run-script";
          direction = "teardown";
          description = "Deregister this cluster's Netbird agent peer";

          provides = [
            planTokens.lab.cleanup
            (planTokens.cluster config.cluster.name).cleanup

            "netbird/agent-deregistered"
          ];

          policy.onFailure = "continue";
          params.bin =
            let
              script = pkgs.writeShellApplication {
                name = "netbird-agent-peer-cleanup";
                runtimeInputs = with pkgs; [ kubectl ];
                text = ''
                  set -eu
                  CONTEXT="''${KUBECONTEXT:-${config.cluster.ref.kubeContext or ""}}"
                  if [ -z "$CONTEXT" ]; then
                    echo "no kube context resolved; skipping agent deregistration" >&2
                    exit 0
                  fi
                  kubectl --context "$CONTEXT" -n ${cfg.agent.namespace} \
                    delete deployment netbird-agent --wait=true --timeout=60s 2>/dev/null || true
                  echo "Netbird agent deregistered (context=$CONTEXT)"
                '';
              };
            in
            "${script}/bin/netbird-agent-peer-cleanup";
        };
      })

      (mkIf (cfg.operator.enable && hasClientSecretRef) {

        shell.packages = [ netbirdClient.cli ];

        steps.netbird-mesh-join = {
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

        steps.netbird-mesh-leave = {
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

      (mkIf cfg.agent.enable {
        bundles.netbird-agent = {
          owner = {
            bootstrap = "install-target";
            steady = "argocd";
          };
          createNamespaces = [ cfg.agent.namespace ];

          awaitRollout = true;

          # The agent cannot start without its setup key, so wait for the
          # Secret rather than for the rollout alone. On the management
          # cluster the operator mints it; on a peer cluster it is projected
          # from the lab's secret store. Either way the wave blocks until the
          # value is really there, and the init container below stays as
          # defence in depth against it disappearing later.
          readyProbe = {
            kind = "jsonpath";
            resource = "secret/${cfg.agent.setupKeyRef.name}";
            namespace = cfg.agent.namespace;
            jsonpath = "{.data.${cfg.agent.setupKeyRef.key}}";
            timeout = "5m";
          };

          requires = lib.optionals cfg.management.enable [

            "netbird/setup-keys/ready"

            "netbird/management/ready"
            "gateway/tls/ready"
          ];
          resources = {
            netbird-agent-sa = {
              apiVersion = "v1";
              kind = "ServiceAccount";
              metadata = {
                name = "netbird-agent";
                namespace = cfg.agent.namespace;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
            };

            netbird-agent-setup-key-reader-role = {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "Role";
              metadata = {
                name = "netbird-agent-setup-key-reader";
                namespace = cfg.agent.namespace;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              rules = [
                {
                  apiGroups = [ "" ];
                  resources = [ "secrets" ];
                  resourceNames = [ cfg.agent.setupKeyRef.name ];

                  verbs = [
                    "get"
                    "list"
                    "watch"
                  ];
                }
              ];
            };

            netbird-agent-setup-key-reader-rb = {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "RoleBinding";
              metadata = {
                name = "netbird-agent-setup-key-reader";
                namespace = cfg.agent.namespace;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "Role";
                name = "netbird-agent-setup-key-reader";
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = "netbird-agent";
                  namespace = cfg.agent.namespace;
                }
              ];
            };

            netbird-agent-state = mkIf cfg.agent.persistence.enable {
              apiVersion = "v1";
              kind = "PersistentVolumeClaim";
              metadata = {
                name = "netbird-agent-state";
                namespace = cfg.agent.namespace;
                labels."app.kubernetes.io/managed-by" = "catallaxy";
              };
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                resources.requests.storage = cfg.agent.persistence.size;
              }
              // optionalAttrs (cfg.agent.persistence.storageClass != null) {
                storageClassName = cfg.agent.persistence.storageClass;
              };
            };

            netbird-agent = {
              apiVersion = "apps/v1";
              kind = "Deployment";
              metadata = {
                name = "netbird-agent";
                namespace = cfg.agent.namespace;
                labels = {
                  "app.kubernetes.io/managed-by" = "catallaxy";
                  "app.kubernetes.io/name" = "netbird-agent";
                  "app.kubernetes.io/component" = "vpn-peer";
                };
              };
              spec = {
                replicas = 1;
                strategy.type = "Recreate";
                selector.matchLabels."app.kubernetes.io/name" = "netbird-agent";
                template = {
                  metadata.labels."app.kubernetes.io/name" = "netbird-agent";
                  spec = {
                    serviceAccountName = "netbird-agent";
                    terminationGracePeriodSeconds = 30;
                    initContainers = [
                      {
                        name = "init-tun";
                        image = cfg.images.wait.ref;
                        command = [
                          "sh"
                          "-c"
                          ''
                            set -eu
                            if [ ! -c /dev/net/tun ]; then
                              mkdir -p /dev/net
                              mknod /dev/net/tun c 10 200 || true
                              chmod 0666 /dev/net/tun || true
                            fi
                          ''
                        ];
                        securityContext = {
                          privileged = true;
                          runAsUser = 0;
                        };
                        volumeMounts = [
                          {
                            name = "dev";
                            mountPath = "/dev";
                          }
                        ];
                      }
                    ]

                    ++ mkWaitForSecrets [
                      {
                        name = "setup-key";
                        secret = cfg.agent.setupKeyRef.name;
                        key = cfg.agent.setupKeyRef.key;
                      }
                    ];
                    containers = [
                      {
                        name = "netbird";
                        image = cfg.images.agent.ref;
                        imagePullPolicy = "IfNotPresent";
                        env = [
                          {
                            name = "NB_SETUP_KEY";
                            valueFrom.secretKeyRef = {
                              name = cfg.agent.setupKeyRef.name;
                              key = cfg.agent.setupKeyRef.key;
                            };
                          }
                          {
                            name = "NB_MANAGEMENT_URL";
                            value = cfg.agent.managementUrl;
                          }
                          {
                            name = "NB_LOG_LEVEL";
                            value = "info";
                          }
                        ]
                        ++ optional hasCaBundle {

                          name = "SSL_CERT_DIR";
                          value = "/etc/ssl/certs:/etc/netbird-ca";
                        }
                        ++ optional (cfg.agent.hostname != null) {
                          name = "NB_HOSTNAME";
                          value = cfg.agent.hostname;
                        }
                        ++ optional (cfg.agent.advertisedRoutes != [ ]) {
                          name = "NB_EXTRA_IFACE_FOUND_ROUTES";
                          value = lib.concatStringsSep "," cfg.agent.advertisedRoutes;
                        };
                        securityContext = {
                          capabilities.add = [
                            "NET_ADMIN"
                            "SYS_RESOURCE"
                            "SYS_ADMIN"
                          ];
                        };
                        lifecycle.preStop.exec.command = [
                          "sh"
                          "-c"
                          "netbird down --force || true; sleep 2"
                        ];
                        volumeMounts = [
                          {
                            name = "netbird-state";
                            mountPath = "/var/lib/netbird";
                          }
                          {
                            name = "dev-net-tun";
                            mountPath = "/dev/net/tun";
                          }
                        ]
                        ++ optional hasCaBundle {
                          name = "lab-ca-dir";
                          mountPath = "/etc/netbird-ca";
                          readOnly = true;
                        };
                        resources = cfg.agent.resources;
                      }
                    ];
                    volumes = [
                      (
                        if cfg.agent.persistence.enable then
                          {
                            name = "netbird-state";
                            persistentVolumeClaim.claimName = "netbird-agent-state";
                          }
                        else
                          {
                            name = "netbird-state";
                            emptyDir = { };
                          }
                      )
                      {
                        name = "dev";
                        hostPath.path = "/dev";
                      }
                      {
                        name = "dev-net-tun";
                        hostPath = {
                          path = "/dev/net/tun";
                          type = "CharDevice";
                        };
                      }
                    ]
                    ++ optional hasCaBundle {
                      name = "lab-ca-dir";
                      configMap = {
                        name = cfg.tls.caBundle.name;
                        items = [
                          {
                            key = cfg.tls.caBundle.key;
                            path = "lab-ca.crt";
                          }
                        ];
                      };
                    };
                  };
                };
              };
            };
          };
        };
      })
    ];
})
  __floeModuleArgs
