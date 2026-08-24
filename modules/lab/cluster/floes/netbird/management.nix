{
  lib,
  cfg,
  nb,
  k8sHelpers,
  mkWaitForSecrets,
}:
let
  inherit (lib) optionalAttrs optional;

  inherit (nb)
    managedBy
    signalDomain
    hasCaBundle
    waitTimeoutStr
    idpClientId
    idpIssuer
    idpJwksUri
    idpAuthorizationEndpoint
    idpBrowserTokenEndpoint
    idpPublicIssuer
    oauthRedirectUrls
    ;

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
        labels = managedBy;
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
        labels = managedBy;
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
        labels = managedBy;
      };
      data."management.tmpl.json" = managementConfigJson;
    };

    netbird-management-svc = {
      apiVersion = "v1";
      kind = "Service";
      metadata = {
        name = "netbird-management";
        namespace = cfg.namespace;
        labels = managedBy;
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
        labels = managedBy // {
          "app.kubernetes.io/name" = "netbird-management";
        };
      };
      spec = {
        replicas = cfg.management.replicas;
        strategy.type = "Recreate";
        selector.matchLabels."app.kubernetes.io/name" = "netbird-management";
        template = {
          metadata = {
            labels = managedBy // {
              "app.kubernetes.io/name" = "netbird-management";
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
in
{
  inherit managementConfigJson;
  resources = netbirdMgmtResources;
}
