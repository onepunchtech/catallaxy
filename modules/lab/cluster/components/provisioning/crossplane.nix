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
    optionalAttrs
    mapAttrs
    mapAttrsToList
    listToAttrs
    nameValuePair
    optional
    optionals
    concatStringsSep
    ;
  cfg = config.components.crossplane;

  # Chart reference
  chartRef = cfg.chart;

  # Provider package references (OCI images)
  providerPackages = {
    digitalocean = "xpkg.upbound.io/crossplane-contrib/provider-upjet-digitalocean:v${cfg.providerVersions.digitalocean}";
    cloudflare = "xpkg.upbound.io/wildbitca/provider-cloudflare-dns:v${cfg.providerVersions.cloudflare}";
    kubernetes = "xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v${cfg.providerVersions.kubernetes}";
    helm = "xpkg.upbound.io/crossplane-contrib/provider-helm:v${cfg.providerVersions.helm}";
  };

  # Generate Provider CRs for each enabled provider
  providerCRs = listToAttrs (
    map (
      name:
      nameValuePair "xp-provider-${name}" {
        apiVersion = "pkg.crossplane.io/v1";
        kind = "Provider";
        metadata = {
          name = "provider-${name}";
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        spec.package = providerPackages.${name};
      }
    ) cfg.providers
  );

  # Generate ProviderConfig CRs for providers with credentials
  providerConfigCRs =
    let
      doConfig = optionalAttrs (cfg.digitalocean.enable && cfg.digitalocean.credentialSecretRef != null) {
        xp-providerconfig-digitalocean = {
          apiVersion = "digitalocean.crossplane.io/v1beta1";
          kind = "ProviderConfig";
          metadata = {
            name = "default";
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec.credentials = {
            source = "Secret";
            secretRef = {
              name = cfg.digitalocean.credentialSecretRef.name;
              namespace = cfg.digitalocean.credentialSecretRef.namespace;
              key = cfg.digitalocean.credentialSecretRef.key;
            };
          };
        };
      };

      cfConfig = optionalAttrs (cfg.cloudflare.enable && cfg.cloudflare.credentialSecretRef != null) {
        xp-providerconfig-cloudflare = {
          apiVersion = "upjet-cloudflare.upbound.io/v1beta1";
          kind = "ProviderConfig";
          metadata = {
            name = "default";
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          spec.credentials = {
            source = "Secret";
            secretRef = {
              name = cfg.cloudflare.credentialSecretRef.name;
              namespace = cfg.cloudflare.credentialSecretRef.namespace;
              key = cfg.cloudflare.credentialSecretRef.key;
            };
          };
        };
      };
    in
    doConfig // cfConfig;

  # Credential secrets (inline tokens for dev/lab use)
  credentialSecrets =
    let
      doSecret = optionalAttrs (cfg.digitalocean.enable && cfg.digitalocean.apiToken != null) {
        xp-do-credentials = {
          apiVersion = "v1";
          kind = "Secret";
          metadata = {
            name = cfg.digitalocean.credentialSecretRef.name;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          type = "Opaque";
          stringData.credentials = builtins.toJSON {
            access_token = cfg.digitalocean.apiToken;
          };
        };
      };

      cfSecret = optionalAttrs (cfg.cloudflare.enable && cfg.cloudflare.apiToken != null) {
        xp-cf-credentials = {
          apiVersion = "v1";
          kind = "Secret";
          metadata = {
            name = cfg.cloudflare.credentialSecretRef.name;
            namespace = cfg.namespace;
            labels."app.kubernetes.io/managed-by" = "catallaxy";
          };
          type = "Opaque";
          stringData.credentials = builtins.toJSON {
            api_token = cfg.cloudflare.apiToken;
          };
        };
      };
    in
    doSecret // cfSecret;

  # DigitalOcean managed resources
  doResources =
    let
      droplets = mapAttrs (name: droplet: {
        apiVersion = "droplet.digitalocean.crossplane.io/v1alpha1";
        kind = "Droplet";
        metadata = {
          name = name;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        spec = {
          forProvider = {
            region = droplet.region;
            size = droplet.size;
            image = droplet.image;
          }
          // optionalAttrs (droplet.sshKeys != [ ]) {
            sshKeys = droplet.sshKeys;
          }
          // optionalAttrs (droplet.userData != null) {
            userData = droplet.userData;
          }
          // optionalAttrs (droplet.vpcUuid != null) {
            vpcUuid = droplet.vpcUuid;
          };
          providerConfigRef.name = "default";
        };
      }) cfg.digitalocean.droplets;

      lbs = mapAttrs (name: lb: {
        apiVersion = "networking.digitalocean.crossplane.io/v1alpha1";
        kind = "Loadbalancer";
        metadata = {
          name = name;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        spec = {
          forProvider = {
            region = lb.region;
            forwardingRule = lb.forwardingRules;
          }
          // optionalAttrs (lb.dropletTag != null) {
            dropletTag = lb.dropletTag;
          };
          providerConfigRef.name = "default";
        };
      }) cfg.digitalocean.loadBalancers;
    in
    droplets // lbs;

  # Cloudflare managed resources
  cfResources =
    let
      zones = mapAttrs (name: zone: {
        apiVersion = "zone.upjet-cloudflare.m.upbound.io/v1alpha1";
        kind = "Zone";
        metadata = {
          name = name;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        spec = {
          forProvider = {
            zone = zone.domain;
            plan = zone.plan;
          }
          // optionalAttrs (zone.accountId != null) {
            accountId = zone.accountId;
          };
          providerConfigRef.name = "default";
        };
      }) cfg.cloudflare.zones;

      records = mapAttrs (name: record: {
        apiVersion = "record.upjet-cloudflare.m.upbound.io/v1alpha1";
        kind = "Record";
        metadata = {
          name = name;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        spec = {
          forProvider = {
            zoneIdRef.name = record.zoneRef;
            name = record.name;
            type = record.type;
            value = record.value;
            proxied = record.proxied;
            ttl = record.ttl;
          };
          providerConfigRef.name = "default";
        };
      }) cfg.cloudflare.records;

      tunnels = mapAttrs (name: tunnel: {
        apiVersion = "tunnel.upjet-cloudflare.m.upbound.io/v1alpha1";
        kind = "Tunnel";
        metadata = {
          name = name;
          labels."app.kubernetes.io/managed-by" = "catallaxy";
        };
        spec = {
          forProvider = {
            accountId = tunnel.accountId;
            name = tunnel.name;
            secret = tunnel.secret;
          };
          providerConfigRef.name = "default";
        };
      }) cfg.cloudflare.tunnels;
    in
    zones // records // tunnels;

  # Secret ref submodule
  secretRefType = types.submodule {
    options = {
      name = mkOption { type = types.str; };
      namespace = mkOption {
        type = types.str;
        default = cfg.namespace;
      };
      key = mkOption {
        type = types.str;
        default = "credentials";
      };
    };
  };
in
{
  options.components.crossplane = {
    enable = mkEnableOption "Crossplane infrastructure provisioning";

    phase = mkOption {
      type = types.str;
      default = "operators";
    };

    version = mkOption {
      type = types.str;
      default = "1.18.2";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.crossplane.chart;
    };

    namespace = mkOption {
      type = types.str;
      default = "crossplane-system";
    };

    providers = mkOption {
      type = types.listOf (
        types.enum [
          "digitalocean"
          "cloudflare"
          "kubernetes"
          "helm"
        ]
      );
      default = [ ];
      description = "Crossplane providers to install";
    };

    providerVersions = {
      digitalocean = mkOption {
        type = types.str;
        default = "0.3.2";
      };
      cloudflare = mkOption {
        type = types.str;
        default = "0.2.5";
      };
      kubernetes = mkOption {
        type = types.str;
        default = "1.2.1";
      };
      helm = mkOption {
        type = types.str;
        default = "1.2.0";
      };
    };

    # --- DigitalOcean ---
    digitalocean = {
      enable = mkOption {
        type = types.bool;
        default = builtins.elem "digitalocean" cfg.providers;
      };

      apiToken = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "DO API token (for dev/lab use). For production, use SOPS-encrypted secrets.";
      };

      credentialSecretRef = mkOption {
        type = types.nullOr secretRefType;
        default = {
          name = "do-credentials";
          namespace = cfg.namespace;
          key = "token";
        };
      };

      droplets = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              region = mkOption {
                type = types.str;
                default = "nyc1";
              };
              size = mkOption {
                type = types.str;
                default = "s-2vcpu-4gb";
              };
              image = mkOption {
                type = types.str;
                default = "ubuntu-24-04-x64";
              };
              sshKeys = mkOption {
                type = types.listOf types.str;
                default = [ ];
              };
              userData = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
              vpcUuid = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
            };
          }
        );
        default = { };
      };

      loadBalancers = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              region = mkOption {
                type = types.str;
                default = "nyc1";
              };
              dropletTag = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
              forwardingRules = mkOption {
                type = types.listOf types.attrs;
                default = [
                  {
                    entryPort = 80;
                    entryProtocol = "http";
                    targetPort = 80;
                    targetProtocol = "http";
                  }
                ];
              };
            };
          }
        );
        default = { };
      };
    };

    # --- Cloudflare ---
    cloudflare = {
      enable = mkOption {
        type = types.bool;
        default = builtins.elem "cloudflare" cfg.providers;
      };

      apiToken = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Cloudflare API token (for dev/lab use). For production, use SOPS-encrypted secrets.";
      };

      credentialSecretRef = mkOption {
        type = types.nullOr secretRefType;
        default = {
          name = "cf-credentials";
          namespace = cfg.namespace;
          key = "token";
        };
      };

      zones = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              domain = mkOption { type = types.str; };
              plan = mkOption {
                type = types.str;
                default = "free";
              };
              accountId = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
            };
          }
        );
        default = { };
      };

      records = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              zoneRef = mkOption {
                type = types.str;
                description = "Name of the Crossplane Zone resource to reference";
              };
              name = mkOption { type = types.str; };
              type = mkOption {
                type = types.enum [
                  "A"
                  "AAAA"
                  "CNAME"
                  "MX"
                  "TXT"
                  "SRV"
                  "NS"
                ];
                default = "A";
              };
              value = mkOption { type = types.str; };
              proxied = mkOption {
                type = types.bool;
                default = false;
              };
              ttl = mkOption {
                type = types.int;
                default = 300;
              };
            };
          }
        );
        default = { };
      };

      tunnels = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              accountId = mkOption { type = types.str; };
              name = mkOption { type = types.str; };
              secret = mkOption { type = types.str; };
            };
          }
        );
        default = { };
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
    };
  };

  config = lib.mkMerge [
    {
      components.crossplane.ref = {
        namespace = cfg.namespace;
        providers = cfg.providers;
      };
    }

    (mkIf cfg.enable {
      # Install Crossplane + provider CRDs declaratively in the crds phase
      phases.crds.bundles.crossplane-crds.yamls =
        [ cataCharts.crossplane.crds ]
        ++ optional cfg.digitalocean.enable cataCharts.crossplaneProviderCrds.provider-upjet-digitalocean
        ++ optional cfg.cloudflare.enable cataCharts.crossplaneProviderCrds.provider-upjet-cloudflare;

      # Crossplane helm chart in operators phase
      phases.${cfg.phase}.bundles.crossplane = {
        helmCharts.crossplane = {
          chart = chartRef;
          releaseName = "crossplane";
          namespace = cfg.namespace;
          createNamespace = true;
          values = { };
        };
        createNamespaces = [ cfg.namespace ];
      };

      # Project lab-level managed secrets into Crossplane's namespace
      secrets.projections = lib.mkMerge [
        (optionalAttrs cfg.digitalocean.enable {
          do-credentials = {
            source = "do-token";
            namespace = cfg.namespace;
            phase = "secrets";
            keys = {
              token.from = "token";
              credentials = {
                from = "token";
                transform = "json-wrap";
                jsonKey = "access_token";
              };
            };
          };
        })
        (optionalAttrs cfg.cloudflare.enable {
          cf-credentials = {
            source = "cf-token";
            namespace = cfg.namespace;
            phase = "secrets";
            keys = {
              token.from = "token";
              credentials = {
                from = "token";
                transform = "json-wrap";
                jsonKey = "api_token";
              };
            };
          };
        })
      ];

      # Provider CRs in infrastructure phase (after Crossplane is running).
      # Credential secrets are injected by SOPS at deploy time (secrets phase).
      phases.infrastructure.bundles.crossplane-providers.resources = providerCRs;

      # ProviderConfig CRs — CRDs are pre-installed in the crds phase
      phases.apps.bundles.crossplane-provider-configs.resources =
        providerConfigCRs;

      # Managed resources in a later phase (after provider configs are ready)
      phases.workloads.bundles.crossplane-resources.resources =
        (if cfg.digitalocean.enable then doResources else { })
        // (if cfg.cloudflare.enable then cfResources else { });
    })
  ];
}
