{
  lab,
  lib,
  config,
  cataCharts,
  ...
}:

let
  inherit (lib) mkOption mkEnableOption types;
  contracts = import ../../../../../lib/contracts { inherit lib; };
  inherit (import ../../../../../lib/floe { inherit lib; }) refs;
in
{
  options.floes.harbor = {
    chart = mkOption {
      type = types.package;
      default = cataCharts.harbor.chart;
    };

    domain = mkOption {
      type = types.str;
      default = "";
      description = "External hostname. Set this to enable HTTPRoute + Certificate.";
    };

    adminPasswordSecret = mkOption {
      type = types.str;
      default = "harbor-admin";
      description = ''
        Name of the Secret carrying the Harbor admin password under key
        `HARBOR_ADMIN_PASSWORD`. Created by the bootstrap Job with a
        random 24-char password if the Secret doesn't already exist.
      '';
    };

    secretKeySecret = mkOption {
      type = types.str;
      default = "harbor-secret-key";
      description = ''
        Secret carrying Harbor's internal 16-char `secretKey` (used for
        encrypting credentials stored in Harbor's database). Created by
        the bootstrap Job if missing.
      '';
    };

    bootstrapImage = mkOption {
      type = types.str;
      default = "alpine/k8s:1.32.4";
      description = "Image for the bootstrap Jobs. Needs kubectl + curl + bash + coreutils + sed + jq.";
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
        default = "harbor-tls";
      };
      caBundle = mkOption {
        type = refs.nullableMountableRef;
        default = config.floes.cert-manager.exports.caBundle;
        description = ''
          Lab CA bundle mounted into the OIDC bootstrap Job so it trusts
          the kanidm issuer's TLS cert. Null disables.
        '';
      };
      caBundleSecret = mkOption {
        type = refs.nullableMountableRef;
        default = config.floes.cert-manager.exports.caBundleSecret;
        description = ''
          Secret form of the same bundle, handed to Harbor's chart-level
          `caBundleSecret` value: its contents load into the trust
          store of harbor-core, jobservice and registry so those Go
          processes can verify the kanidm OIDC issuer's TLS cert.
          Distinct from `caBundle` (mounted into the OIDC bootstrap Job)
          because the chart accepts a Secret, not a ConfigMap, here.
        '';
      };
    };

    storage = {
      storageClass = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      registry.size = mkOption {
        type = types.str;
        default = "50Gi";
      };
      jobLog.size = mkOption {
        type = types.str;
        default = "1Gi";
      };
      database.size = mkOption {
        type = types.str;
        default = "5Gi";
      };
      redis.size = mkOption {
        type = types.str;
        default = "1Gi";
      };
      trivy.size = mkOption {
        type = types.str;
        default = "5Gi";
      };
    };

    oidc = {
      enable = mkEnableOption "OIDC authentication";
      providerName = mkOption {
        type = types.str;
        default = "OIDC";
        description = "Human-friendly provider name shown in Harbor's UI.";
      };
      issuerUrl = mkOption {
        type = types.str;
        default = "";
        example = "https://idm.example.com/oauth2/openid/harbor";
      };
      clientId = mkOption {
        type = types.str;
        default = "harbor";
      };
      client = mkOption {
        type = contracts.oidc.nullableClient;
        default = config.floes.kanidm.exports.oauth2Clients.${config.floes.harbor.oidc.clientId} or null;
        defaultText = lib.literalExpression "config.floes.kanidm.exports.oauth2Clients.\${oidc.clientId}";
        description = ''
          The identity provider's published record for this client, or
          null when nothing in the lab publishes one.

          Defaults to kanidm's. Assign any floe's equivalent export to
          run against a different provider; the default names kanidm but
          the type does not. Null is also how you opt out.
        '';
      };
      clientSecretRef = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              namespace = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Namespace containing the secret. Defaults to harbor's namespace.";
              };
              key = mkOption {
                type = types.str;
                default = "CLIENT_SECRET";
              };
            };
          }
        );
        default = null;
        description = ''
          Secret containing the OIDC client secret. The bootstrap Job
          reads it via kubectl (not envFrom) so it can live in a
          different namespace than harbor: the typical case is the
          kanidm OAuth2 client secret living in the kanidm namespace.
          The Harbor module emits a Role + RoleBinding granting the
          bootstrap SA read access to this specific Secret.
        '';
      };
      scopes = mkOption {
        type = types.listOf types.str;
        default = [
          "openid"
          "email"
          "profile"
          "groups"
          "offline_access"
        ];
      };
      groupsClaim = mkOption {
        type = types.str;
        default = "groups";
      };
      userClaim = mkOption {
        type = types.str;
        default = "preferred_username";
      };
      adminGroup = mkOption {
        type = types.str;
        default = "";
        description = "OIDC group whose members get Harbor admin privileges.";
      };
      groupSuffix = mkOption {
        type = types.str;
        default = "";
        example = "@idm.lab.test";
        description = ''
          Suffix the IdP appends to every group entry in the OIDC `groups`
          claim. Required for IdPs (e.g. kanidm) that emit group SPNs like
          `<group>@<domain>` rather than bare names. The project bootstrap
          appends this to every group member entity name so the stored
          Harbor user-group matches what arrives in the OIDC token.
        '';
      };
      autoOnboard = mkOption {
        type = types.bool;
        default = true;
        description = "Create local Harbor user records on first OIDC login.";
      };
      verifyCert = mkOption {
        type = types.bool;
        default = true;
      };
    };

    trivy.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Trivy vulnerability scanner.";
    };

    robots = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              description = mkOption {
                type = types.str;
                default = "";
              };

              duration = mkOption {
                type = types.int;
                default = -1;
                description = "Lifetime in days; -1 = unlimited.";
              };
              level = mkOption {
                type = types.enum [
                  "system"
                  "project"
                ];
                default = "system";
              };
              permissions = mkOption {
                type = types.listOf types.attrs;
                default = [
                  {
                    kind = "project";
                    namespace = "*";
                    access = [
                      {
                        resource = "repository";
                        action = "pull";
                      }
                    ];
                  }
                ];
                description = ''
                  List of Harbor permission objects (the shape Harbor
                  expects under `spec.permissions`). For project-scoped
                  access across all projects use `kind = "project"` with
                  `namespace = "*"`. For a single project use the project
                  name. System-level robots use `kind = "system"` with
                  `namespace = "/"` and system-scope resources (rare,
                  mostly admin operations).
                '';
              };
              secretName = mkOption {
                type = types.str;
                default = "harbor-${name}-credentials";
                description = ''
                  Name of the Secret the bootstrap Job creates. Secret has
                  type `kubernetes.io/dockerconfigjson` ready for use as
                  an imagePullSecret. Re-created idempotently: if the
                  Secret exists, the Job leaves it alone.
                '';
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Harbor robot accounts to provision after Harbor comes up. The
        bootstrap Job creates each via the Harbor API and writes the
        resulting dockerconfigjson into the named Secret in harbor's
        namespace. Cross-cluster delivery is up to the consumer
        (typically via a `lab.steps.xcs-*` entry).
      '';
    };

    projects = mkOption {
      type = types.attrsOf (
        types.submodule (
          { ... }:
          {
            options = {
              public = mkOption {
                type = types.bool;
                default = false;
                description = "Whether anonymous users can pull from this project.";
              };

              autoScan = mkOption {
                type = types.bool;
                default = false;
                description = "Automatically scan images on push.";
              };

              preventVuln = mkOption {
                type = types.bool;
                default = false;
                description = "Prevent pulling of images with vulnerabilities at or above `severity`.";
              };

              severity = mkOption {
                type = types.nullOr (
                  types.enum [
                    "low"
                    "medium"
                    "high"
                    "critical"
                  ]
                );
                default = null;
                description = "Severity threshold for `preventVuln`.";
              };

              reuseSysCveAllowlist = mkOption {
                type = types.bool;
                default = true;
                description = "Reuse the system-level CVE allowlist in this project.";
              };

              storageQuota = mkOption {
                type = types.int;
                default = -1;
                description = "Storage quota in bytes. -1 = unlimited.";
              };

              proxyCache = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      registryType = mkOption {
                        type = types.enum [
                          "docker-hub"
                          "harbor"
                          "docker-registry"
                          "ghcr"
                          "quay"
                          "azure-acr"
                          "aws-ecr"
                          "google-gcr"
                        ];
                        description = "Harbor registry-endpoint type.";
                      };
                      endpointUrl = mkOption {
                        type = types.str;
                        description = "Upstream registry URL.";
                      };
                      credentialUsername = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                      };
                      credentialPasswordRef = mkOption {
                        type = types.nullOr (
                          types.submodule {
                            options = {
                              name = mkOption {
                                type = types.str;
                                description = "Secret name in the harbor namespace.";
                              };
                              key = mkOption {
                                type = types.str;
                                description = "Key within the Secret.";
                              };
                            };
                          }
                        );
                        default = null;
                      };
                    };
                  }
                );
                default = null;
                description = ''
                  When set, the project becomes a pull-through cache of an
                  upstream registry. The bootstrap Job creates the registry
                  endpoint via /api/v2.0/registries before creating the
                  project itself.
                '';
              };

              members = mkOption {
                type = types.attrsOf (
                  types.submodule (
                    { ... }:
                    {
                      options = {
                        entityType = mkOption {
                          type = types.enum [
                            "user"
                            "group"
                          ];
                          default = "group";
                          description = "OIDC group (default) or local/OIDC user.";
                        };
                        role = mkOption {
                          type = types.enum [
                            "projectAdmin"
                            "maintainer"
                            "developer"
                            "guest"
                            "limitedGuest"
                          ];
                          default = "developer";
                        };
                      };
                    }
                  )
                );
                default = { };
                description = ''
                  Project members keyed by entity name (OIDC group name or
                  username). The bootstrap Job adds or updates each via
                  /api/v2.0/projects/{name}/members.
                '';
              };

              retention = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      schedule = mkOption {
                        type = types.str;
                        default = "Manual";
                        description = "Cron expression or \"Manual\".";
                      };
                      rules = mkOption {
                        type = types.listOf types.attrs;
                        default = [ ];
                        description = "Raw Harbor retention rule objects.";
                      };
                    };
                  }
                );
                default = null;
              };

              immutableTagRules = mkOption {
                type = types.listOf types.attrs;
                default = [ ];
                description = ''
                  Raw Harbor immutable_rule objects POSTed to
                  /api/v2.0/projects/{name}/immutabletagrules. Harbor
                  returns 409 on duplicate rules (treated as success).
                '';
              };

              cveAllowlist = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Project-scoped CVE IDs to allow.";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Harbor projects to provision after Harbor comes up. The bootstrap
        Job creates each via the Harbor API and applies the declared
        settings idempotently. Removing a project from this attrset does
        NOT delete it from Harbor: manual cleanup via the Harbor UI is
        required (protects against accidental image-data loss).
      '';
    };

    metrics.enable = mkOption {
      type = types.bool;
      default = false;
    };

    gateway = {
      enable = mkOption {
        type = types.bool;
        default = true;
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
