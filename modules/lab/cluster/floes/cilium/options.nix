{
  lib,
  cataCharts,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkDefault
    types
    ;
in
{
  config.floes.cilium.namespace = mkDefault "kube-system";

  options.floes.cilium = {

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

    gatewayAPI = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Be the cluster's Gateway API implementation.

          Off by default, because enabling cilium is usually asking for a CNI
          and this is a second, unrelated job. On it emits a GatewayClass and
          a Gateway named exactly what the gateway floe names its own, so a
          lab that wanted a CNI got two implementations claiming one set of
          listeners and routes, and which one won depended on reconcile order.
          That is now refused outright, which turned a default nobody chose
          into an error nobody expected.

          It also exports no `routing` capability, so floes that ask whether
          their HTTPRoute will have a parent see nothing here and refuse.
          Turning this on is worth doing when cilium is the gateway you want;
          it is not worth doing by accident.
        '';
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
        description = "Audit mode: log policy violations instead of enforcing";
      };
    };

    egressGateway = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable egress gateway for controlled outbound traffic";
      };
    };

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

    operator = {
      replicas = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Number of Cilium operator replicas";
      };
    };

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
  };
}
