{
  lab,
  config,
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  inherit (import ../../../../../lib/floe { inherit lib; }) gatewayOptions;
  contracts = import ../../../../../lib/contracts { inherit lib; };
in
{

  config.floes.kanidm.version = lib.mkDefault "1.10.4";

  config.floes.kanidm.origin = lib.mkDefault "https://${config.floes.kanidm.domain}";

  options.floes.kanidm = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.kanidm.chart;
      description = "Helm chart to install. Defaults to the chart catallaxy pins.";
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
      issuerRef = contracts.tls.issuerRefOption {
        default = contracts.tls.defaultIssuer config;
        description = "Issuer that signs the serving certificate. Null mints none.";
      };
      secretName = mkOption {
        type = types.str;
        default = "kanidm-tls";
        description = "Secret the issued certificate lands in.";
      };
    };

    storage = {
      size = mkOption {
        type = types.str;
        default = "10Gi";
        description = "Size of the volume holding the identity database.";
      };
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "StorageClass for it. Null takes the cluster default.";
      };
    };

    replicas = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "How many kanidm replicas to run.";
    };

    users = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            displayName = mkOption {
              type = types.str;
              description = "Name shown for this person in the UI.";
            };
            email = mkOption {
              type = types.str;
              description = "Address mail for this person is sent to.";
            };
            legalName = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Legal name, when it differs from the display name. Null omits it.";
            };
            credentialsTokenTtl = mkOption {
              type = types.int;
              default = 3600;
              description = "Seconds a credential-reset token stays valid.";
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
                      description = "Login shell recorded in the POSIX attributes.";
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
      description = "People to provision in kanidm. Each becomes a KanidmPersonAccount the operator reconciles.";
    };

    groups = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            members = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Names of accounts or groups that belong to this group.";
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
                      description = "Numeric group id. Null lets kanidm allocate one.";
                    };
                  };
                }
              );
              default = null;
              description = "POSIX attributes for this group, for systems that resolve users through it. Null omits them.";
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
                      description = "Weakest credential a member may authenticate with.";
                    };
                    passwordMinimumLength = mkOption {
                      type = types.int;
                      default = 12;
                      description = "Shortest password accepted.";
                    };
                    authSessionExpiry = mkOption {
                      type = types.int;
                      default = 86400;
                      description = "Seconds a session stays authenticated.";
                    };
                    privilegeExpiry = mkOption {
                      type = types.int;
                      default = 900;
                      description = "Seconds an elevated-privilege window lasts before it has to be re-established.";
                    };
                  };
                }
              );
              default = null;
              description = "Authentication policy for members of this group. Null leaves kanidm's default.";
            };
          };
        }
      );
      default = { };
      description = "Groups to provision. Membership is what drives authorisation everywhere else, since scopes and roles are mapped from groups rather than set per user.";
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
              description = "Name shown for this client on the consent screen.";
            };
            origin = mkOption {
              type = types.str;
              description = "Origin the client is served from, which kanidm checks redirects against.";
            };
            namespace = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Namespace for this OAuth2Client CR and its generated secret. null = kanidm namespace.";
            };
            redirectUrls = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Redirect URLs the client may be sent back to after login.";
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
                    group = mkOption {
                      type = types.str;
                      description = "Group the scopes are granted to.";
                    };
                    scopes = mkOption {
                      type = types.listOf types.str;
                      default = [
                        "openid"
                        "email"
                        "groups"
                      ];
                      description = "Scopes its members receive.";
                    };
                  };
                }
              );
              default = [ ];
              description = "Scopes granted to members of a group, so authorisation follows group membership rather than being set per user.";
            };
            supScopeMap = mkOption {
              type = types.listOf (
                types.submodule {
                  options = {
                    group = mkOption {
                      type = types.str;
                      description = "Group the supplemental scopes are granted to.";
                    };
                    scopes = mkOption {
                      type = types.listOf types.str;
                      description = "Scopes its members receive in addition to the mapped ones.";
                    };
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
                    name = mkOption {
                      type = types.str;
                      description = "Claim name to emit.";
                    };
                    joinStrategy = mkOption {
                      type = types.enum [
                        "csv"
                        "ssv"
                        "array"
                      ];
                      default = "array";
                      description = "How several values are combined into the claim: as an array, or joined by spaces or commas.";
                    };
                    valuesMap = mkOption {
                      type = types.listOf (
                        types.submodule {
                          options = {
                            group = mkOption {
                              type = types.str;
                              description = "Group whose members get these values.";
                            };
                            values = mkOption {
                              type = types.listOf types.str;
                              description = "Values they get.";
                            };
                          };
                        }
                      );
                      description = "Values to put in the claim, per group.";
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
              description = "Send the short username rather than the full SPN as the subject. Some clients cannot handle an SPN.";
            };
            allowLocalhostRedirect = mkOption {
              type = types.bool;
              default = false;
              description = "Permit redirects to localhost, which a desktop or CLI client needs and a web client should not have.";
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
      description = "OAuth2 clients to provision, one per relying party that authenticates against kanidm.";
    };

    serviceAccounts = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            displayName = mkOption {
              type = types.str;
              description = "Name shown for this account in the UI.";
            };
            entryManagedBy = mkOption {
              type = types.str;
              description = "Group or account that manages this service account";
            };
            mail = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Mail addresses for this account.";
            };
            accountValidFrom = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "RFC 3339 time before which the account cannot authenticate. Null means no lower bound.";
            };
            accountExpire = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "RFC 3339 time after which it cannot. Null means it does not expire.";
            };
            apiTokens = mkOption {
              type = types.listOf (
                types.submodule {
                  options = {
                    label = mkOption {
                      type = types.str;
                      description = "Label for this API token, shown in kanidm.";
                    };
                    purpose = mkOption {
                      type = types.enum [
                        "readonly"
                        "readwrite"
                      ];
                      default = "readonly";
                      description = "What the token may do.";
                    };
                    secretName = mkOption {
                      type = types.str;
                      description = "Secret the token is written to.";
                    };
                    expiry = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "RFC3339 expiry (e.g. 2026-12-31T00:00:00Z)";
                    };
                  };
                }
              );
              default = [ ];
              description = "API tokens to mint for this service account.";
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
      description = "Name of the Kanidm custom resource, which the operator uses to name what it creates.";
    };

    gateway = gatewayOptions {
      inherit config;
      withMode = true;
    };

  };
}
