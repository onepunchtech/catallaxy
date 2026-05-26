{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    optionalAttrs
    optionals
    optionalString
    ;
  cfg = config.components.cilium;
  clusterProvisioner = config.cluster.provisioner;

  # Chart reference with fallback
  chartRef = cfg.chart;

  # Compute effective k8sServiceHost based on provider
  effectiveK8sServiceHost =
    if cfg.k8sServiceHost != null then
      cfg.k8sServiceHost
    else if clusterProvisioner == "external" then
      "10.96.0.1" # CAPI: Kubernetes service ClusterIP
    else
      "localhost"; # k3d/docker

  # Compute effective k8sServicePort based on provider
  effectiveK8sServicePort =
    if cfg.k8sServicePort != null then
      cfg.k8sServicePort
    else if clusterProvisioner == "external" then
      "443" # CAPI: Kubernetes service port
    else
      "6443"; # k3d/docker

  # Helm values shared between IR and auto-deploy rendering
  ciliumValues = {
    kubeProxyReplacement = cfg.kubeProxyReplacement;
    k8sServiceHost = effectiveK8sServiceHost;
    k8sServicePort = effectiveK8sServicePort;
    hubble = {
      enabled = cfg.hubble.enable;
    }
    // optionalAttrs cfg.hubble.enable {
      relay.enabled = cfg.hubble.relay.enable;
      ui.enabled = cfg.hubble.ui.enable;
      tls.auto.method = "cronJob";
    };
    ipam.mode = cfg.ipam.mode;
    operator.replicas = cfg.operator.replicas;
    gatewayAPI.enabled = cfg.gatewayAPI.enable;
    ingressController = optionalAttrs cfg.ingressController.enable {
      enabled = true;
      loadbalancerMode = cfg.ingressController.loadbalancerMode;
    };
    bgpControlPlane.enabled = cfg.bgp.enable;
    l2announcements.enabled = cfg.l2.announcements;
    externalIPs.enabled = cfg.lbIPAM.enable;
    encryption = optionalAttrs cfg.encryption.enable {
      enabled = true;
      type = cfg.encryption.type;
      nodeEncryption = cfg.encryption.nodeEncryption;
    };
    hostFirewall.enabled = cfg.networkPolicy.hostFirewall;
    policyAuditMode = cfg.networkPolicy.policyAuditMode;
    egressGateway.enabled = cfg.egressGateway.enable;
    bandwidthManager = optionalAttrs cfg.bandwidthManager.enable {
      enabled = true;
      bbr = cfg.bandwidthManager.bbr;
    };
    cluster = optionalAttrs cfg.clusterMesh.enable {
      name =
        if cfg.clusterMesh.clusterName != null then cfg.clusterMesh.clusterName else config.cluster.name;
      id = cfg.clusterMesh.clusterID;
    };
  };

  # Pre-rendered Cilium manifests for k3s auto-deploy (Nix build time)
  ciliumValuesFile = pkgs.writeText "cilium-values.yaml" (builtins.toJSON ciliumValues);

  ciliumAutoDeployManifest =
    pkgs.runCommand "cilium-auto-deploy"
      {
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      }
      ''
        helm template cilium ${chartRef} \
          --namespace kube-system \
          --values ${ciliumValuesFile} \
          > $out
      '';

in
{
  # =========================================================================
  # PART 1: High-level options
  # =========================================================================

  options.components.cilium = {
    enable = mkEnableOption "Cilium CNI";

    phase = mkOption {
      type = types.str;
      default = "networking";
      description = "Deployment phase this component belongs to";
    };

    version = mkOption {
      type = types.str;
      default = "1.16.3";
      description = "Cilium version";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.cilium.chart;
      description = "Cilium Helm chart derivation (default: cataCharts.cilium)";
    };

    kubeProxyReplacement = mkOption {
      type = types.bool;
      default = true;
      description = "Replace kube-proxy with eBPF-based load balancing";
    };

    # --- Gateway API ---
    gatewayAPI = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Kubernetes Gateway API support (replaces legacy Ingress)";
      };

      tls = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable HTTPS listener on the default Gateway with cert-manager TLS";
        };

        issuerRef = mkOption {
          type = types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                description = "cert-manager Issuer or ClusterIssuer name";
              };
              kind = mkOption {
                type = types.str;
                default = "ClusterIssuer";
                description = "Issuer kind";
              };
            };
          };
          default = {
            name = "lab-ca";
            kind = "ClusterIssuer";
          };
          description = "cert-manager issuer for the Gateway wildcard certificate";
        };

        domain = mkOption {
          type = types.str;
          default = "";
          description = "Base domain for wildcard cert (e.g. homelab.test → *.homelab.test)";
        };

        passthrough = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Enable TLS passthrough listener on the Gateway (for backends that terminate TLS themselves)";
          };
        };
      };
    };

    # --- Ingress Controller ---
    ingressController = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable Cilium's native ingress controller";
      };

      loadbalancerMode = mkOption {
        type = types.enum [
          "shared"
          "dedicated"
        ];
        default = "shared";
        description = "LoadBalancer mode for ingress";
      };
    };

    # --- BGP Control Plane ---
    bgp = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable BGP control plane for advertising routes to external routers";
      };

      localASN = mkOption {
        type = types.int;
        default = 65001;
        description = "Local BGP Autonomous System Number for this cluster";
      };

      peers = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              address = mkOption {
                type = types.str;
                description = "BGP peer IP address";
              };
              asn = mkOption {
                type = types.int;
                description = "BGP peer Autonomous System Number";
              };
            };
          }
        );
        default = [ ];
        description = "BGP peers to establish sessions with";
      };
    };

    # --- L2 Announcements & LB IPAM ---
    l2 = {
      announcements = mkOption {
        type = types.bool;
        default = false;
        description = "Enable L2 (ARP/NDP) announcements for service IPs";
      };
    };

    lbIPAM = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable LoadBalancer IP Address Management";
      };

      pools = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              name = mkOption {
                type = types.str;
                default = "default";
                description = "Pool name";
              };
              cidrs = mkOption {
                type = types.listOf types.str;
                description = "CIDR ranges for IP allocation";
              };
            };
          }
        );
        default = [ ];
        description = "IP address pools for LoadBalancer services";
      };
    };

    # --- Encryption ---
    encryption = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable transparent encryption of pod-to-pod traffic";
      };

      type = mkOption {
        type = types.enum [
          "wireguard"
          "ipsec"
        ];
        default = "wireguard";
        description = "Encryption backend (WireGuard recommended)";
      };

      nodeEncryption = mkOption {
        type = types.bool;
        default = false;
        description = "Also encrypt node-to-node traffic";
      };
    };

    # --- Network Policies ---
    networkPolicy = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Kubernetes NetworkPolicy enforcement";
      };

      clusterNetworkPolicy = mkOption {
        type = types.bool;
        default = false;
        description = "Enable CiliumClusterwideNetworkPolicy CRD";
      };

      hostFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Enable host-level firewall enforcement";
      };

      policyAuditMode = mkOption {
        type = types.bool;
        default = false;
        description = "Audit mode — log policy violations instead of enforcing";
      };
    };

    # --- Egress Gateway ---
    egressGateway = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable egress gateway for controlled outbound traffic";
      };
    };

    # --- Bandwidth Manager ---
    bandwidthManager = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable bandwidth manager for rate limiting";
      };

      bbr = mkOption {
        type = types.bool;
        default = false;
        description = "Enable BBR TCP congestion control";
      };
    };

    # --- Cluster Mesh ---
    clusterMesh = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable multi-cluster networking via ClusterMesh";
      };

      clusterName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Cluster name for mesh identity (default: cluster.name)";
      };

      clusterID = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "Unique cluster ID within the mesh (0-255)";
      };
    };

    # --- Hubble Observability ---
    hubble = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Hubble network observability";
      };

      relay.enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Hubble Relay";
      };

      ui.enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable Hubble UI dashboard";
      };
    };

    # --- IPAM ---
    ipam = {
      mode = mkOption {
        type = types.enum [
          "kubernetes"
          "cluster-pool"
        ];
        default = "kubernetes";
        description = "IP Address Management mode";
      };
    };

    # --- Operator ---
    operator = {
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of Cilium operator replicas";
      };
    };

    # --- K8s API ---
    k8sServiceHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Kubernetes API server host. When null, auto-configured based on cluster provider:
        - external (CAPI): uses Kubernetes service ClusterIP (10.96.0.1)
        - docker (k3d): uses localhost
      '';
    };

    k8sServicePort = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Kubernetes API server port. When null, auto-configured based on cluster provider:
        - external (CAPI): 443 (Kubernetes service port)
        - docker (k3d): 6443
      '';
    };

    # --- Computed refs ---
    ref = mkOption {
      type = types.attrs;
      readOnly = true;
      description = "Computed references for Cilium";
    };
  };

  # =========================================================================
  # PART 2: Computed refs
  # =========================================================================

  config = lib.mkMerge [
    {
      components.cilium.ref = {
        gatewayClassName = "cilium";
        namespace = "kube-system";
        k8sServiceHost = effectiveK8sServiceHost;
        k8sServicePort = effectiveK8sServicePort;
        passthroughEnabled = cfg.gatewayAPI.tls.passthrough.enable;
      };
    }

    # =========================================================================
    # PART 3: CRD management and phase ordering
    # =========================================================================

    (mkIf cfg.enable {
      # Install Gateway API CRDs in the crds phase
      phases.crds.bundles.gateway-api-crds.yamls = mkIf cfg.gatewayAPI.enable [
        k8sSpecs.standaloneCrds.gateway-api
      ];

      # =========================================================================
      # PART 4: Phase writer
      # =========================================================================

      # Main Cilium helm chart in networking phase
      phases.${cfg.phase}.bundles.cilium.helmCharts.cilium = {
        chart = chartRef;
        releaseName = "cilium";
        namespace = "kube-system";
        values = ciliumValues;
      };

      # GatewayClass + Gateway resource in infrastructure phase (after CRDs are installed)
      phases.infrastructure.bundles.cilium-gateway.resources = mkIf cfg.gatewayAPI.enable {
        "cilium-gatewayclass" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "GatewayClass";
          metadata = {
            name = "cilium";
          };
          spec = {
            controllerName = "io.cilium/gateway-controller";
          };
        };
        "default-gateway" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "Gateway";
          metadata = {
            name = "default-gateway";
            namespace = "kube-system";
          };
          spec = {
            gatewayClassName = "cilium";
            listeners = [
              {
                name = "http";
                protocol = "HTTP";
                port = 80;
                allowedRoutes.namespaces.from = "All";
              }
            ]
            ++ optionals (cfg.gatewayAPI.tls.enable && cfg.gatewayAPI.tls.domain != "") [
              {
                name = "https";
                protocol = "HTTPS";
                port = 443;
                allowedRoutes.namespaces.from = "All";
                tls = {
                  mode = "Terminate";
                  certificateRefs = [
                    {
                      name = "gateway-tls";
                    }
                  ];
                };
              }
            ]
            ++ optionals cfg.gatewayAPI.tls.passthrough.enable [
              {
                name = "tls-passthrough";
                protocol = "TLS";
                port = 443;
                allowedRoutes.namespaces.from = "All";
                tls = {
                  mode = "Passthrough";
                };
              }
            ];
          };
        };
      };

      # Gateway TLS wildcard certificate (in infrastructure phase, same as gateway)
      phases.infrastructure.bundles.cilium-gateway-tls.resources =
        mkIf (cfg.gatewayAPI.enable && cfg.gatewayAPI.tls.enable && cfg.gatewayAPI.tls.domain != "")
          {
            "gateway-tls-cert" = {
              apiVersion = "cert-manager.io/v1";
              kind = "Certificate";
              metadata = {
                name = "gateway-tls";
                namespace = "kube-system";
              };
              spec = {
                secretName = "gateway-tls";
                issuerRef = {
                  name = cfg.gatewayAPI.tls.issuerRef.name;
                  kind = cfg.gatewayAPI.tls.issuerRef.kind;
                };
                dnsNames = [
                  cfg.gatewayAPI.tls.domain
                  "*.${cfg.gatewayAPI.tls.domain}"
                ];
              };
            };
          };

      # BGP + LB IPAM resources (after Cilium CRDs are available)
      phases.infrastructure.bundles.cilium-bgp.resources =
        let
          poolResources = lib.listToAttrs (
            map (pool: {
              name = "lb-pool-${pool.name}";
              value = {
                apiVersion = "cilium.io/v2alpha1";
                kind = "CiliumLoadBalancerIPPool";
                metadata.name = pool.name;
                spec.blocks = map (cidr: { inherit cidr; }) pool.cidrs;
              };
            }) cfg.lbIPAM.pools
          );

          bgpResources = optionalAttrs (cfg.bgp.enable && cfg.bgp.peers != [ ]) {
            "bgp-cluster-config" = {
              apiVersion = "cilium.io/v2alpha1";
              kind = "CiliumBGPClusterConfig";
              metadata.name = "default";
              spec = {
                nodeSelector.matchLabels = { };
                bgpInstances = [
                  {
                    name = "default";
                    localASN = cfg.bgp.localASN;
                    peers = lib.imap0 (i: peer: {
                      name = "peer-${toString i}";
                      peerASN = peer.asn;
                      peerAddress = peer.address;
                      peerConfigRef.name = "default";
                    }) cfg.bgp.peers;
                  }
                ];
              };
            };

            "bgp-peer-config" = {
              apiVersion = "cilium.io/v2alpha1";
              kind = "CiliumBGPPeerConfig";
              metadata.name = "default";
              spec = {
                families = [
                  {
                    afi = "ipv4";
                    safi = "unicast";
                    advertisements.matchLabels = {
                      "cilium.io/bgp-advertise" = "lb";
                    };
                  }
                ];
              };
            };

            "bgp-advertisement" = {
              apiVersion = "cilium.io/v2alpha1";
              kind = "CiliumBGPAdvertisement";
              metadata = {
                name = "lb-services";
                labels = {
                  "cilium.io/bgp-advertise" = "lb";
                };
              };
              spec = {
                advertisements = [
                  {
                    advertisementType = "Service";
                    selector = { };
                    service = {
                      addresses = [ "LoadBalancerIP" ];
                    };
                  }
                ];
              };
            };
          };
        in
        lib.mkIf (cfg.lbIPAM.enable || cfg.bgp.enable) (poolResources // bgpResources);

      # Auto-deploy Cilium at k3d boot so nodes get CNI immediately
      provisioner.k3d.autoDeployManifests = mkIf (config.cluster.provisioner == "k3d") [
        {
          name = "cilium";
          content = ciliumAutoDeployManifest;
        }
      ];
    })
  ];
}
