{
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    mapAttrs
    mapAttrsToList
    optionalAttrs
    optional
    ;
  cfg = config.components.kanidm;
  kaniopEnabled = config.components.kaniop.enable or false;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Gateway route resource — supports both TLS passthrough and HTTP terminate modes.
  # Kanidm only speaks h2 over TLS (port 8443), so passthrough is the default:
  # the gateway forwards raw TLS to kanidm based on SNI.
  gatewayParentRef = {
    name = cfg.gateway.gatewayRef;
  }
  // optionalAttrs (cfg.gateway.gatewayNamespace != null) {
    namespace = cfg.gateway.gatewayNamespace;
  }
  // optionalAttrs (cfg.gateway.mode == "passthrough") {
    sectionName = "tls-passthrough";
  };

  routeResource = optionalAttrs (cfg.gateway.enable && cfg.domain != "idm.example.com") {
    kanidm-route =
      if cfg.gateway.mode == "passthrough" then
        {
          apiVersion = "gateway.networking.k8s.io/v1alpha2";
          kind = "TLSRoute";
          metadata = {
            name = "kanidm";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [ gatewayParentRef ];
            hostnames = [ cfg.domain ];
            rules = [
              {
                backendRefs = [
                  {
                    name = cfg.instanceName;
                    port = 8443;
                  }
                ];
              }
            ];
          };
        }
      else
        {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            name = "kanidm";
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec = {
            parentRefs = [ gatewayParentRef ];
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
                    name = cfg.instanceName;
                    port = 8443;
                  }
                ];
              }
            ];
          };
        };
  };

  # BackendTLSPolicy — tells the gateway to use TLS when connecting to Kanidm backend
  backendTlsPolicy = optionalAttrs (cfg.gateway.enable && cfg.gateway.mode == "terminate") {
    kanidm-backend-tls = {
      apiVersion = "gateway.networking.k8s.io/v1alpha3";
      kind = "BackendTLSPolicy";
      metadata = {
        name = "kanidm-backend-tls";
        namespace = cfg.namespace;
        labels."app.kubernetes.io/managed-by" = "catallaxy";
      };
      spec = {
        targetRefs = [
          {
            group = "";
            kind = "Service";
            name = cfg.instanceName;
          }
        ];
        validation = {
          hostname = cfg.domain;
        }
        // (if hasTrustBundle then {
          caCertificateRefs = [
            {
              group = "";
              kind = "ConfigMap";
              name = caBundleConfigMap;
            }
          ];
        } else {
          wellKnownCACertificates = "System";
        });
      };
    };
  };

  # Kaniop Kanidm CR
  # Whether trust-manager is distributing the lab CA bundle
  hasTrustBundle =
    (config.components.trust-manager.enable or false)
    && (config.components.cert-manager.selfSignedCA.enable or false);
  caBundleConfigMap = config.components.cert-manager.ref.caBundleConfigMap or "lab-ca-bundle";
  caBundleKey = config.components.cert-manager.ref.caBundleKey or "ca.crt";

  kanidmCR = optionalAttrs kaniopEnabled {
    kanidm-cr = {
      apiVersion = "kaniop.rs/v1beta1";
      kind = "Kanidm";
      metadata = {
        name = cfg.instanceName;
        namespace = cfg.namespace;
        labels = {
          "app.kubernetes.io/managed-by" = "catallaxy";
        };
      };
      spec = {
        domain = cfg.domain;
        replicaGroups = [
          {
            name = "default";
            replicas = cfg.replicas;
          }
        ];
      }
      // optionalAttrs (cfg.oauth2ClientNamespaceSelector != null) {
        oauth2ClientNamespaceSelector = cfg.oauth2ClientNamespaceSelector;
      }
      // optionalAttrs (cfg.tls.issuerRef != null) {
        tlsSecretName = cfg.tls.secretName;
      }
      // optionalAttrs (cfg.storage.storageClass != null) {
        storage = {
          storageClassName = cfg.storage.storageClass;
          size = cfg.storage.size;
        };
      };
    };
  };

  # TLS Certificate
  tlsCertResource = optionalAttrs (cfg.tls.issuerRef != null) {
    kanidm-tls = {
      apiVersion = "cert-manager.io/v1";
      kind = "Certificate";
      metadata = {
        name = cfg.tls.secretName;
        namespace = cfg.namespace;
        labels = {
          "app.kubernetes.io/managed-by" = "catallaxy";
        };
      };
      spec = {
        secretName = cfg.tls.secretName;
        issuerRef = {
          name = cfg.tls.issuerRef.name;
          kind = cfg.tls.issuerRef.kind;
        };
        dnsNames = [
          cfg.domain
        ]
        # Internal SAN only works with local CAs — ACME rejects non-public suffixes
        ++ optional (!(config.components.cert-manager.acme.enable or false))
          "${cfg.instanceName}.${cfg.namespace}.svc.cluster.local";
      };
    };
  };

  # Kaniop Group CRDs
  groupResources = mapAttrs (name: group: {
    apiVersion = "kaniop.rs/v1beta1";
    kind = "KanidmGroup";
    metadata = {
      inherit name;
      namespace = cfg.namespace;
      labels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    spec = {
      kanidmRef.name = cfg.instanceName;
      members = group.members;
    }
    // optionalAttrs (group.mail != [ ]) {
      mail = group.mail;
    }
    // optionalAttrs (group.entryManagedBy != null) {
      entryManagedBy = group.entryManagedBy;
    }
    // optionalAttrs (group.posixAttributes != null) {
      posixAttributes =
        { }
        // optionalAttrs (group.posixAttributes.gidnumber != null) {
          gidnumber = group.posixAttributes.gidnumber;
        };
    }
    // optionalAttrs (group.accountPolicy != null) {
      accountPolicy = {
        credentialTypeMinimum = group.accountPolicy.credentialTypeMinimum;
        passwordMinimumLength = group.accountPolicy.passwordMinimumLength;
        authSessionExpiry = group.accountPolicy.authSessionExpiry;
        privilegeExpiry = group.accountPolicy.privilegeExpiry;
      };
    };
  }) cfg.groups;

  # Kaniop PersonAccount CRDs
  personResources = mapAttrs (name: user: {
    apiVersion = "kaniop.rs/v1beta1";
    kind = "KanidmPersonAccount";
    metadata = {
      inherit name;
      namespace = cfg.namespace;
      labels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    spec = {
      kanidmRef.name = cfg.instanceName;
      personAttributes = {
        displayname = user.displayName;
        mail = [ user.email ];
      }
      // optionalAttrs (user.legalName != null) {
        legalname = user.legalName;
      }
      // optionalAttrs (user.accountValidFrom != null) {
        accountValidFrom = user.accountValidFrom;
      }
      // optionalAttrs (user.accountExpire != null) {
        accountExpire = user.accountExpire;
      };
      credentialsTokenTtl = user.credentialsTokenTtl;
    }
    // optionalAttrs (user.posixAttributes != null) {
      posixAttributes =
        { }
        // optionalAttrs (user.posixAttributes.gidnumber != null) {
          gidnumber = user.posixAttributes.gidnumber;
        }
        // optionalAttrs (user.posixAttributes.loginshell != "/bin/bash") {
          loginshell = user.posixAttributes.loginshell;
        };
    };
  }) cfg.users;

  # Kaniop OAuth2Client CRDs
  oauth2Resources = mapAttrs (name: client: {
    apiVersion = "kaniop.rs/v1beta1";
    kind = "KanidmOAuth2Client";
    metadata = {
      inherit name;
      namespace = if client.namespace != null then client.namespace else cfg.namespace;
      labels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    spec = {
      kanidmRef = {
        name = cfg.instanceName;
      }
      // optionalAttrs (client.namespace != null) {
        namespace = cfg.namespace;
      };
      displayname = if client.displayName != "" then client.displayName else name;
      origin = client.origin;
      redirectUrl =
        if client.redirectUrls != [ ] then client.redirectUrls else [ "${client.origin}/oauth2/callback" ];
    }
    // optionalAttrs client.public { public = true; }
    // optionalAttrs (client.secretTemplate != null) {
      secretTemplate.labels = client.secretTemplate;
    }
    // optionalAttrs (client.scopeMap != [ ]) {
      scopeMap = map (sm: {
        group = sm.group;
        scopes = sm.scopes;
      }) client.scopeMap;
    }
    // optionalAttrs (client.supScopeMap != [ ]) {
      supScopeMap = map (sm: {
        group = sm.group;
        scopes = sm.scopes;
      }) client.supScopeMap;
    }
    // optionalAttrs (client.claimMap != [ ]) {
      claimMap = map (cm: {
        name = cm.name;
        joinStrategy = cm.joinStrategy;
        valuesMap = map (vm: {
          group = vm.group;
          values = vm.values;
        }) cm.valuesMap;
      }) client.claimMap;
    }
    // optionalAttrs client.preferShortUsername { preferShortUsername = true; }
    // optionalAttrs client.allowLocalhostRedirect { allowLocalhostRedirect = true; }
    // optionalAttrs client.disableConsentPrompt { disableConsentPrompt = true; }
    // optionalAttrs client.allowInsecureClientDisablePkce { allowInsecureClientDisablePkce = true; }
    // optionalAttrs (!client.strictRedirectUrl) { strictRedirectUrl = false; };
  }) cfg.oauth2Clients;

  # Kaniop ServiceAccount CRDs
  serviceAccountResources = mapAttrs (name: sa: {
    apiVersion = "kaniop.rs/v1beta1";
    kind = "KanidmServiceAccount";
    metadata = {
      inherit name;
      namespace = cfg.namespace;
      labels = {
        "app.kubernetes.io/managed-by" = "catallaxy";
      };
    };
    spec = {
      kanidmRef.name = cfg.instanceName;
      serviceAccountAttributes = {
        displayname = sa.displayName;
        entryManagedBy = sa.entryManagedBy;
      }
      // optionalAttrs (sa.mail != [ ]) {
        mail = sa.mail;
      }
      // optionalAttrs (sa.accountValidFrom != null) {
        accountValidFrom = sa.accountValidFrom;
      }
      // optionalAttrs (sa.accountExpire != null) {
        accountExpire = sa.accountExpire;
      };
    }
    // optionalAttrs (sa.apiTokens != [ ]) {
      apiTokens = map (
        tok:
        {
          label = tok.label;
          purpose = tok.purpose;
          secretName = tok.secretName;
        }
        // optionalAttrs (tok.expiry != null) {
          expiry = tok.expiry;
        }
      ) sa.apiTokens;
    };
  }) cfg.serviceAccounts;

  hasProvisioning =
    cfg.users != { } || cfg.groups != { } || cfg.oauth2Clients != { } || cfg.serviceAccounts != { };
in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.kanidm = {
    enable = mkEnableOption "Kanidm identity management";

    phase = mkOption {
      type = types.str;
      default = "infrastructure";
    };
    version = mkOption {
      type = types.str;
      default = "1.4.2";
    };
    namespace = mkOption {
      type = types.str;
      default = "kanidm";
    };
    chart = mkOption {
      type = types.package;
      default = cataCharts.kanidm.chart;
    };

    domain = mkOption {
      type = types.str;
      default = "idm.example.com";
    };
    origin = mkOption {
      type = types.str;
      default = "https://idm.example.com";
    };

    tls = {
      issuerRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              kind = mkOption {
                type = types.str;
                default = "ClusterIssuer";
              };
            };
          }
        );
        default = null;
      };
      secretName = mkOption {
        type = types.str;
        default = "kanidm-tls";
      };
    };

    storage = {
      size = mkOption {
        type = types.str;
        default = "10Gi";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
    };

    backup = {
      enable = mkOption {
        type = types.bool;
        default = false;
      };
      schedule = mkOption {
        type = types.str;
        default = "0 2 * * *";
      };
    };

    users = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            displayName = mkOption { type = types.str; };
            email = mkOption { type = types.str; };
            groups = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };
            legalName = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
            credential = mkOption {
              type = types.enum [
                "token"
                "password"
                "passkey"
              ];
              default = "token";
            };
            passwordSecretRef = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    name = mkOption { type = types.str; };
                    key = mkOption {
                      type = types.str;
                      default = "password";
                    };
                  };
                }
              );
              default = null;
            };
            credentialsTokenTtl = mkOption {
              type = types.int;
              default = 3600;
            };
            accountValidFrom = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "ISO 8601 timestamp — account is invalid before this time";
            };
            accountExpire = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "ISO 8601 timestamp — account expires after this time";
            };
            posixAttributes = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    gidnumber = mkOption {
                      type = types.nullOr types.int;
                      default = null;
                      description = "Unix UID/GID (auto-generated if null)";
                    };
                    loginshell = mkOption {
                      type = types.str;
                      default = "/bin/bash";
                    };
                  };
                }
              );
              default = null;
              description = "POSIX/Unix attributes for SSH and Linux integration";
            };
          };
        }
      );
      default = { };
    };

    groups = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            members = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };
            mail = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Group email addresses";
            };
            entryManagedBy = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Group or account that manages this group";
            };
            posixAttributes = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    gidnumber = mkOption {
                      type = types.nullOr types.int;
                      default = null;
                    };
                  };
                }
              );
              default = null;
            };
            accountPolicy = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    credentialTypeMinimum = mkOption {
                      type = types.enum [
                        "any"
                        "mfa"
                        "passkey"
                        "attested_passkey"
                      ];
                      default = "any";
                    };
                    passwordMinimumLength = mkOption {
                      type = types.int;
                      default = 12;
                    };
                    authSessionExpiry = mkOption {
                      type = types.int;
                      default = 86400;
                    };
                    privilegeExpiry = mkOption {
                      type = types.int;
                      default = 900;
                    };
                  };
                }
              );
              default = null;
            };
          };
        }
      );
      default = { };
    };

    oauth2ClientNamespaceSelector = mkOption {
      type = types.nullOr types.attrs;
      default = null;
      description = "Namespace selector for KanidmOAuth2Client discovery. {} = all namespaces.";
    };

    oauth2Clients = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            displayName = mkOption {
              type = types.str;
              default = "";
            };
            origin = mkOption { type = types.str; };
            namespace = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Namespace for this OAuth2Client CR and its generated secret. null = kanidm namespace.";
            };
            redirectUrls = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };
            public = mkOption {
              type = types.bool;
              default = true;
            };
            secretTemplate = mkOption {
              type = types.nullOr (types.attrsOf types.str);
              default = null;
              description = "Extra labels for the kaniop-generated credential secret";
            };
            scopeMap = mkOption {
              type = types.listOf (
                types.submodule {
                  options = {
                    group = mkOption { type = types.str; };
                    scopes = mkOption {
                      type = types.listOf types.str;
                      default = [
                        "openid"
                        "email"
                        "groups"
                      ];
                    };
                  };
                }
              );
              default = [ ];
            };
            supScopeMap = mkOption {
              type = types.listOf (
                types.submodule {
                  options = {
                    group = mkOption { type = types.str; };
                    scopes = mkOption { type = types.listOf types.str; };
                  };
                }
              );
              default = [ ];
              description = "Supplementary scopes (optional claims not used for authz)";
            };
            claimMap = mkOption {
              type = types.listOf (
                types.submodule {
                  options = {
                    name = mkOption { type = types.str; };
                    joinStrategy = mkOption {
                      type = types.enum [
                        "csv"
                        "ssv"
                        "array"
                      ];
                      default = "array";
                    };
                    valuesMap = mkOption {
                      type = types.listOf (
                        types.submodule {
                          options = {
                            group = mkOption { type = types.str; };
                            values = mkOption { type = types.listOf types.str; };
                          };
                        }
                      );
                    };
                  };
                }
              );
              default = [ ];
              description = "Custom claim mappings from group membership";
            };
            preferShortUsername = mkOption {
              type = types.bool;
              default = false;
            };
            allowLocalhostRedirect = mkOption {
              type = types.bool;
              default = false;
            };
            disableConsentPrompt = mkOption {
              type = types.bool;
              default = false;
              description = "Skip user consent screen (for admin-managed apps)";
            };
            allowInsecureClientDisablePkce = mkOption {
              type = types.bool;
              default = false;
              description = "Disable PKCE enforcement for confidential clients whose OIDC library doesn't support it (e.g. Dex)";
            };
            strictRedirectUrl = mkOption {
              type = types.bool;
              default = true;
              description = "Require exact redirect URL matching";
            };
          };
        }
      );
      default = { };
    };

    serviceAccounts = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            displayName = mkOption { type = types.str; };
            entryManagedBy = mkOption {
              type = types.str;
              description = "Group or account that manages this service account";
            };
            mail = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };
            accountValidFrom = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
            accountExpire = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
            apiTokens = mkOption {
              type = types.listOf (
                types.submodule {
                  options = {
                    label = mkOption { type = types.str; };
                    purpose = mkOption {
                      type = types.enum [
                        "readonly"
                        "readwrite"
                      ];
                      default = "readonly";
                    };
                    secretName = mkOption { type = types.str; };
                    expiry = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "RFC3339 expiry (e.g. 2026-12-31T00:00:00Z)";
                    };
                  };
                }
              );
              default = [ ];
            };
          };
        }
      );
      default = { };
      description = "Service accounts (bots/daemons) with API tokens";
    };

    instanceName = mkOption {
      type = types.str;
      default = "kanidm";
    };

    gateway = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      mode = mkOption {
        type = types.enum [
          "terminate"
          "passthrough"
        ];
        default = "terminate";
        description = "TLS mode: 'terminate' uses HTTPRoute + BackendTLSPolicy, 'passthrough' uses TLSRoute (raw TLS to backend)";
      };
      gatewayRef = mkOption {
        type = types.str;
        default = "default-gateway";
      };
      gatewayNamespace = mkOption {
        type = types.nullOr types.str;
        default = "kube-system";
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
    };
  };

  # =========================================================================
  # PART 2: Computed refs and config
  # =========================================================================

  config = lib.mkMerge [
    {
      components.kanidm.ref =
        let
          internalHost = "${cfg.instanceName}.${cfg.namespace}.svc.cluster.local";
          # With ACME, the cert only covers the public domain — internal services
          # must use the public URL (routed in-cluster through the gateway).
          useAcme = config.components.cert-manager.acme.enable or false;
          effectiveHost = if useAcme then cfg.domain else internalHost;
          effectiveUrl = if useAcme then cfg.origin else "https://${internalHost}:8443";
        in
        {
          host = effectiveHost;
          namespace = cfg.namespace;
          port = if useAcme then 443 else 8443;
          url = effectiveUrl;
          externalUrl = cfg.origin;
          domain = cfg.domain;
          instanceName = cfg.instanceName;
          oidcIssuer = "${cfg.origin}/oauth2/openid/";
          oidcDiscovery = "${cfg.origin}/.well-known/openid-configuration";
          oauth2Clients = mapAttrs (name: _: {
            issuer = "${cfg.origin}/oauth2/openid/${name}";
            internalIssuer = "${effectiveUrl}/oauth2/openid/${name}";
            clientId = name;
          }) cfg.oauth2Clients;
          caSecretRef = {
            name = cfg.tls.secretName;
            namespace = cfg.namespace;
            key = "ca.crt";
          };
          serviceAccounts = mapAttrs (name: sa: {
            apiTokenSecrets = map (tok: {
              inherit (tok) label purpose secretName;
            }) sa.apiTokens;
          }) cfg.serviceAccounts;
        };
    }

    # =========================================================================
    # PART 3: Phase writer - Main Kanidm deployment
    # =========================================================================

    (mkIf cfg.enable {
      phases.${cfg.phase}.bundles.kanidm = {
        # Main resources (Kanidm CR or helm, plus TLS and gateway route)
        resources =
          (if kaniopEnabled then kanidmCR else { }) // tlsCertResource // routeResource // backendTlsPolicy;

        # Helm chart (when not using Kaniop)
        helmCharts.kanidm = mkIf (!kaniopEnabled) {
          chart = chartRef;
          releaseName = "kanidm";
          namespace = cfg.namespace;
          createNamespace = true;
          values = {
            image.tag = cfg.version;
            replicas = cfg.replicas;

            kanidm = {
              domain = cfg.domain;
              origin = cfg.origin;
            };

            persistence = {
              enabled = true;
              size = cfg.storage.size;
            }
            // optionalAttrs (cfg.storage.storageClass != null) {
              storageClass = cfg.storage.storageClass;
            };
          }
          // optionalAttrs cfg.backup.enable {
            backup = {
              enabled = true;
              schedule = cfg.backup.schedule;
            };
          }
          // optionalAttrs (cfg.tls.issuerRef != null) {
            tls.secretName = cfg.tls.secretName;
          };
        };

        # Namespace created by kaniop component (operators phase)
      };
    })

    # =========================================================================
    # PART 4: Phase writer - Provisioning (users, groups, OAuth2 clients)
    # =========================================================================

    # kaniop CRDs are installed in the crds phase by the kaniop component

    (mkIf (cfg.enable && kaniopEnabled && hasProvisioning) {
      # Provisioning resources go in a later phase (databases)
      phases.databases.bundles.kanidm-db.resources =
        groupResources // personResources // oauth2Resources // serviceAccountResources;
    })
  ];
}
