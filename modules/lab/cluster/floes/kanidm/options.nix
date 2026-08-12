{
  lab,
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
in
{

  config.floes.kanidm.version = lib.mkDefault "1.10.4";

  config.floes.kanidm.origin = lib.mkDefault "https://${config.floes.kanidm.domain}";

  options.floes.kanidm = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.kanidm.chart;
    };

    domain = mkOption {
      type = types.str;
      default = "idm.example.com";
      description = ''
        Public hostname this instance is served on. Every issuer URL a
        consumer receives is built from it, so a lab that sets nothing
        else must set this.
      '';
    };
    origin = mkOption {
      type = types.str;
      defaultText = lib.literalExpression ''"https://''${config.floes.kanidm.domain}"'';
      description = ''
        Public origin, i.e. scheme + `domain`. Kanidm treats this as the
        canonical origin for OAuth2 redirect validation.

        Tracks `domain` by default. It used to default to the literal
        sentinel independently, so a lab that set `domain` and not
        `origin`, which is the obvious thing to write, silently
        advertised `https://idm.example.com/...` through
        `exports.oidcIssuer` and every client's `issuer`, and consumers
        wired themselves to it (2026-07-31). Override only when the
        origin genuinely differs from the served hostname.
      '';
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

        default = config.floes.cert-manager.exports.defaultIssuerRef or null;
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

    users = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            displayName = mkOption { type = types.str; };
            email = mkOption { type = types.str; };
            legalName = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
            credentialsTokenTtl = mkOption {
              type = types.int;
              default = 3600;
            };
            accountValidFrom = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "ISO 8601 timestamp. Account is invalid before this time.";
            };
            accountExpire = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "ISO 8601 timestamp. Account expires after this time.";
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
      description = ''
        Override which namespaces this instance discovers
        `KanidmOAuth2Client` CRs in. `{ }` = all namespaces; a label
        selector = matching namespaces; `null` = derive it.

        Normally leave this alone. The floe derives it from the clients
        you declared: name `oauth2Clients.<id>.namespace` and discovery
        widens to `{ }` automatically. Setting the two independently is
        how a client ends up somewhere its instance never looks, which
        produces no CR status and no error: just an OIDC client that
        never registers.

        A label selector cannot match namespaces the framework creates
        via `createNamespaces`; those carry no labels. An assertion
        catches that combination.
      '';
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
              default = false;
              description = ''
                Make this a PKCE-only public client.

                Defaults to confidential, matching the CRD's own advice
                ("prefer using confidential client types if possible").
                The distinction is not cosmetic: kaniop mints
                `<id>-kanidm-oauth2-credentials` ONLY for a confidential
                client, so a public one leaves anything needing machine
                credentials: a token exchange, a server-side bootstrap,
                pointed at a Secret that never exists. `exports` answers
                that as `clientSecretRef = null` so consumers can branch.

                Set true for a client that only ever does interactive
                login from a browser or CLI, where shipping a secret
                would be wrong.
              '';
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
            generateCredentials = mkOption {
              type = types.bool;
              default = false;
              description = ''
                If true, kaniop creates a Secret named
                `<name>-kanidm-service-account-credentials` containing the
                service account's password (key: `password`). Useful for
                downstream systems that need HTTP Basic Auth credentials
                (e.g. an OCI registry's htpasswd).
              '';
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
      tier = mkOption {
        type = types.enum [
          "public"
          "internal"
        ];

        default = lab.policy.exposure.defaultTier or "public";
        description = "Lab network tier (public | internal).";
      };
    };

  };
}
