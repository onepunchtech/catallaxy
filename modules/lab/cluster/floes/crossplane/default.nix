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
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions;
  planTokens = import ../../../../../lib/plan-tokens.nix { inherit lib; };
  cfg = config.floes.crossplane;
in
{
  imports = [
    (floeOptions {
      name = "crossplane";
      version = "1.18.2";
    })
    ./options.nix
  ];

  config = lib.mkIf cfg.enable (
    let
      inherit (lib)
        mkIf
        optionalAttrs
        mapAttrs
        mapAttrsToList
        listToAttrs
        nameValuePair
        optional
        optionals
        concatStringsSep
        ;
      cidrLib = import ../../../../../lib/util/network.nix { inherit lib; };
      kappLib = import ../../../../../lib/util/kapp.nix { inherit lib; };

      doksClusterExternalNameDiscoverer = pkgs.writeShellApplication {
        name = "discover-doks-cluster-external-name";
        runtimeInputs = with pkgs; [
          kubectl
          coreutils
          gnugrep
          gnused
          curl
          jq
        ];
        text = builtins.readFile ./scripts/doks-cluster-uuid.sh;
      };

      mkDoksVersionValidator =
        clusterName: pins: kubeContext:
        pkgs.writeShellApplication {
          name = "validate-doks-versions-${clusterName}";
          runtimeInputs = with pkgs; [
            kubectl
            coreutils
            curl
            jq
          ];
          text = ''
            PINS=${lib.escapeShellArg (lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "${n}=${v}") pins))}
            KUBECONTEXT=${lib.escapeShellArg kubeContext}
            export PINS KUBECONTEXT
            exec bash ${./scripts/validate-doks-versions.sh}
          '';
        };

      chartRef = cfg.chart;

      doReservedCidrs = [
        "10.244.0.0/16"
        "10.245.0.0/16"
        "10.246.0.0/16"
        "10.247.0.0/16"
      ];

      doRegionReservedCidrs = {
        nyc1 = [ "10.10.0.0/16" ];
      };

      cidrIsDoReserved = cidr: cidr != null && lib.any (r: cidrLib.cidrsOverlap cidr r) doReservedCidrs;

      cidrIsRegionReserved =
        region: cidr:
        if cidr == null then
          [ ]
        else
          lib.filter (r: cidrLib.cidrsOverlap cidr r) (doRegionReservedCidrs.${region} or [ ]);

      isValidDoksSlug =
        v:
        let
          parts = builtins.split "^([0-9]+)\\.([0-9]+)\\.([0-9]+)-do\\.([0-9]+)$" v;
          matched = builtins.length parts == 3 && (builtins.elemAt parts 1) != null;
          patch = if matched then builtins.elemAt (builtins.elemAt parts 1) 3 else null;
        in
        matched && patch != "0";

      providerPackages = {
        digitalocean = "xpkg.upbound.io/crossplane-contrib/provider-upjet-digitalocean:v${cfg.providerVersions.digitalocean}";
        cloudflare = "xpkg.upbound.io/wildbitca/provider-cloudflare-dns:v${cfg.providerVersions.cloudflare}";
        kubernetes = "xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v${cfg.providerVersions.kubernetes}";
        helm = "xpkg.upbound.io/crossplane-contrib/provider-helm:v${cfg.providerVersions.helm}";
      };

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
                token = cfg.digitalocean.apiToken;
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
          k8sClusters = mapAttrs (name: cluster: {
            apiVersion = "kubernetes.digitalocean.crossplane.io/v1alpha1";
            kind = "Cluster";

            metadata = {
              name = name;
              labels."app.kubernetes.io/managed-by" = "catallaxy";
            };
            spec = {
              forProvider = {
                region = cluster.region;
                version = cluster.version;
                name = name;
                ha = cluster.ha;
                autoUpgrade = cluster.autoUpgrade;
                surgeUpgrade = cluster.surgeUpgrade;
                nodePool = [
                  (
                    {
                      name = cluster.nodePool.name;
                      size = cluster.nodePool.size;
                      nodeCount = cluster.nodePool.nodeCount;
                      autoScale = cluster.nodePool.autoScale;
                    }
                    // optionalAttrs (cluster.nodePool.minNodes != null) {
                      minNodes = cluster.nodePool.minNodes;
                    }
                    // optionalAttrs (cluster.nodePool.maxNodes != null) {
                      maxNodes = cluster.nodePool.maxNodes;
                    }
                  )
                ];
              }
              // optionalAttrs (cluster.clusterSubnet != null) {
                clusterSubnet = cluster.clusterSubnet;
              }
              // optionalAttrs (cluster.serviceSubnet != null) {
                serviceSubnet = cluster.serviceSubnet;
              };
              providerConfigRef.name = "default";

              writeConnectionSecretToRef = {
                name = "${name}-cluster-connection";
                namespace = "crossplane-system";
              };
            };
          }) cfg.digitalocean.kubernetesClusters;

          k8sClusterRebase =
            lib.optionalAttrs (k8sClusters != { } && config.floes.delivery.exports.appliedByKapp)
              {
                digitalocean-cluster-rebase = {
                  apiVersion = "kapp.k14s.io/v1alpha1";
                  kind = "Config";
                  metadata.name = "digitalocean-cluster-rebase";
                  rebaseRules =
                    let
                      match = {
                        apiVersionKindMatcher = {
                          apiVersion = "kubernetes.digitalocean.crossplane.io/v1alpha1";
                          kind = "Cluster";
                        };
                      };
                      preserve = path: {
                        inherit path;
                        type = "copy";
                        sources = [ "existing" ];
                        resourceMatchers = [ match ];
                      };
                    in
                    [
                      (preserve [
                        "metadata"
                        "annotations"
                        "crossplane.io/external-name"
                      ])
                      (preserve [
                        "metadata"
                        "annotations"
                        "crossplane.io/external-create-pending"
                      ])
                      (preserve [
                        "metadata"
                        "annotations"
                        "crossplane.io/external-create-succeeded"
                      ])
                      (preserve [
                        "metadata"
                        "annotations"
                        "crossplane.io/external-create-failed"
                      ])
                      (preserve [
                        "metadata"
                        "annotations"
                        "crossplane.io/paused"
                      ])
                      (preserve [
                        "metadata"
                        "annotations"
                        "upjet.crossplane.io/provider-meta"
                      ])
                      (preserve [
                        "metadata"
                        "finalizers"
                      ])
                      (preserve [ "status" ])
                    ];
                };
              };
        in
        droplets // lbs // k8sClusters // k8sClusterRebase;

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

    in
    {

      cluster.kubernetes.uncheckedResources = [
        "kubernetes.digitalocean.crossplane.io/v1alpha1/Cluster"
      ];

      cluster.provisions = lib.optionalAttrs cfg.digitalocean.enable (
        lib.mapAttrs (_: _: {
          resourceKind = "cluster.kubernetes.digitalocean.crossplane.io";
          externalNameDiscoveryBin = "${doksClusterExternalNameDiscoverer}/bin/discover-doks-cluster-external-name";
        }) cfg.digitalocean.kubernetesClusters
      );

      floes.crossplane.steps =
        let
          pins = lib.mapAttrs (_: cluster: cluster.version) (cfg.digitalocean.kubernetesClusters or { });
          hasPins = cfg.digitalocean.enable && pins != { };
          validator = mkDoksVersionValidator config.cluster.name pins config.cluster.ref.kubeContext;
        in
        lib.optionalAttrs hasPins {
          validate-doks-versions = {
            kind = "run-script";
            direction = "deploy";
            description = "Validate pinned DOKS version(s) are still offered by DO";
            provides = [ planTokens.lab.preflightOk ];
            before = planTokens.wantsAll [
              planTokens.lab.secrets
              planTokens.lab.services
            ];
            params = {
              bin = "${validator}/bin/validate-doks-versions-${config.cluster.name}";
              env = [
                {
                  name = "DO_API_TOKEN";
                  secret = "do-token";
                  key = "token";
                }
              ];
            };
          };
        };

      assertions =

        lib.concatLists (
          lib.mapAttrsToList (
            name: c:
            lib.optional (cidrIsDoReserved c.clusterSubnet) {
              assertion = false;
              message = ''
                floes.crossplane.digitalocean.kubernetesClusters.${name}.clusterSubnet
                = ${c.clusterSubnet} overlaps a DO-reserved range
                (one of ${builtins.toJSON doReservedCidrs}). DOKS
                rejects cluster creation with `422` on any pod or
                service CIDR overlap. Pick a range outside that
                block.
              '';
            }
            ++ lib.optional (cidrIsDoReserved c.serviceSubnet) {
              assertion = false;
              message = ''
                floes.crossplane.digitalocean.kubernetesClusters.${name}.serviceSubnet
                = ${c.serviceSubnet} overlaps a DO-reserved range
                (one of ${builtins.toJSON doReservedCidrs}). DOKS
                rejects cluster creation with `422` on any pod or
                service CIDR overlap. Pick a range outside that
                block.
              '';
            }
            ++ lib.optional (!isValidDoksSlug c.version) {
              assertion = false;
              message = ''
                floes.crossplane.digitalocean.kubernetesClusters.${name}.version
                = "${c.version}" doesn't match the expected DOKS
                slug `\d+\.\d+\.\d+-do\.\d+` with a nonzero
                `.do.N` suffix (e.g. `1.36.0-do.2`). DO rarely
                publishes `.do.0` slugs; cluster create fails with
                `invalid version slug`. Check
                `doctl kubernetes options versions` for valid
                values.
              '';
            }
          ) (cfg.digitalocean.kubernetesClusters or { })
        );

      warnings = lib.concatLists (
        lib.mapAttrsToList (
          name: c:
          let
            csRegionHits = cidrIsRegionReserved c.region c.clusterSubnet;
            ssRegionHits = cidrIsRegionReserved c.region c.serviceSubnet;
          in
          map (r: ''
            floes.crossplane.digitalocean.kubernetesClusters.${name}.clusterSubnet
            = ${c.clusterSubnet} overlaps ${r}, which has been
            observed reserved in DO region "${c.region}". If DO has
            since freed this range you can ignore; otherwise expect
            cluster create to fail with `422 reserved for
            DigitalOcean internal use`.
          '') csRegionHits
          ++ map (r: ''
            floes.crossplane.digitalocean.kubernetesClusters.${name}.serviceSubnet
            = ${c.serviceSubnet} overlaps ${r}, which has been
            observed reserved in DO region "${c.region}". If DO has
            since freed this range you can ignore; otherwise expect
            cluster create to fail with `422 reserved for
            DigitalOcean internal use`.
          '') ssRegionHits
        ) (cfg.digitalocean.kubernetesClusters or { })
      );

      floes.crossplane.network = {

        declared = true;

        egress.internet.ports = [ 443 ];

      };

      floes.crossplane.imagesComplete = true;

      floes.crossplane.images.crossplane = {

        repository = "crossplane/crossplane";

        tag = "v1.18.2";

      };

      floes.crossplane.bundles.crossplane-crds = {
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        yamls = [
          cataCharts.crossplane.crds
        ]
        ++ optional cfg.digitalocean.enable cataCharts.crossplaneProviderCrds.provider-upjet-digitalocean
        ++ optional cfg.cloudflare.enable cataCharts.crossplaneProviderCrds.provider-upjet-cloudflare;
        provides = [
          "crossplane/crds/established"
          "kind:pkg.crossplane.io/Provider"
          "kind:pkg.crossplane.io/Configuration"
          "kind:pkg.crossplane.io/Function"
        ];
      };

      floes.crossplane.bundles.crossplane = {

        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        helmCharts.crossplane = {
          chart = chartRef;
          releaseName = "crossplane";
          namespace = cfg.namespace;
          createNamespace = true;

          kustomize = {
            enable = true;
            patches = kappLib.mkPreserveRuntimePatches [
              {
                kind = "Secret";
                name = "crossplane-root-ca";
              }
              {
                kind = "Secret";
                name = "crossplane-tls-client";
              }
              {
                kind = "Secret";
                name = "crossplane-tls-server";
              }
            ];
          };

          values = {
            image.repository = "docker.io/${cfg.images.crossplane.repository}";
            image.tag = cfg.images.crossplane.tag;
          };
        };
        createNamespaces = [ cfg.namespace ];

        requires = [ "crossplane/crds/established" ];
        provides = [ "crossplane/operator/ready" ];
        readyProbe = {
          kind = "condition";
          resource = "deployment/crossplane";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "5m";
        };
      };

      secrets.projections = lib.mkMerge [
        (optionalAttrs cfg.digitalocean.enable {
          do-credentials = {
            source = "do-token";
            namespace = cfg.namespace;
            keys = {
              token.from = "token";
              credentials = {
                from = "token";
                transform = "json-wrap";
                jsonKey = "token";
              };
            };
          };
        })
        (optionalAttrs cfg.cloudflare.enable {
          cf-credentials = {
            source = "cf-token";
            namespace = cfg.namespace;
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

      floes.crossplane.bundles.crossplane-providers.owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };
      floes.crossplane.bundles.crossplane-providers.resources = providerCRs;
      floes.crossplane.bundles.crossplane-providers.requires = [
        "crossplane/operator/ready"
      ];
      floes.crossplane.bundles.crossplane-providers.provides = [
        "crossplane/providers/installed"
        "kind:digitalocean.crossplane.io/ProviderConfig"
        "kind:upjet-cloudflare.upbound.io/ProviderConfig"
      ];

      floes.crossplane.bundles.crossplane-provider-configs.owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };
      floes.crossplane.bundles.crossplane-provider-configs.resources = providerConfigCRs;

      floes.crossplane.bundles.crossplane-provider-configs.requires = [
        "crossplane/providers/installed"
      ];
      floes.crossplane.bundles.crossplane-provider-configs.provides = [
        "crossplane/provider-configs/ready"
        "kind:droplet.digitalocean.crossplane.io/Droplet"
        "kind:kubernetes.digitalocean.crossplane.io/Cluster"
        "kind:networking.digitalocean.crossplane.io/Loadbalancer"
        "kind:record.upjet-cloudflare.m.upbound.io/Record"
        "kind:tunnel.upjet-cloudflare.m.upbound.io/Tunnel"
        "kind:zone.upjet-cloudflare.m.upbound.io/Zone"
      ];

      floes.crossplane.bundles.crossplane-resources.owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };
      floes.crossplane.bundles.crossplane-resources.resources =
        (if cfg.digitalocean.enable then doResources else { })
        // (if cfg.cloudflare.enable then cfResources else { });
      floes.crossplane.bundles.crossplane-resources.requires = [
        "crossplane/provider-configs/ready"
      ];
      floes.crossplane.bundles.crossplane-resources.provides = [
        "crossplane/managed-resources/reconciling"
      ];

    }
  );
}
