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
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe;
in
(mkFloe {
  name = "cilium";
  version = "1.16.3";
  imports = [ ./options.nix ];
  module =
    {
      config,
      lib,
      k8sSpecs,
      cfg,
      peers,
      ...
    }:
    let
      inherit (lib)
        optionalAttrs
        optionals
        optionalString
        ;
      clusterProvisioner = config.cluster.provisioner;

      chartRef = cfg.chart;

      effectiveK8sServiceHost =
        if cfg.k8sServiceHost != null then
          cfg.k8sServiceHost
        else if clusterProvisioner == "external" then
          "10.96.0.1"
        else
          "localhost";

      effectiveK8sServicePort =
        if cfg.k8sServicePort != null then
          cfg.k8sServicePort
        else if clusterProvisioner == "external" then
          "443"
        else
          "6443";

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

      assertions = [
        {
          assertion =
            !(cfg.gatewayAPI.enable && cfg.gatewayAPI.tls.enable) || (peers.cert-manager.issuance != null);
          message = "cilium gatewayAPI.tls.enable requires floes.cert-manager to be enabled (reconciles the Certificate CR).";
        }
      ];

      floes.cilium.network = {

        declared = true;

      };

      floes.cilium.imagesComplete = true;

      floes.cilium.images.agent = {

        registry = "quay.io";

        repository = "cilium/cilium";

        tag = "v1.17.2";

        digest = "sha256:3c4c9932b5d8368619cb922a497ff2ebc8def5f41c18e410bcc84025fcd385b1";

      };

      floes.cilium.images.operator = {

        registry = "quay.io";

        repository = "cilium/operator-generic";

        tag = "v1.17.2";

        digest = "sha256:81f2d7198366e8dec2903a3a8361e4c68d47d19c68a0d42f0b7b6e3f0523f249";

      };

      floes.cilium.images.envoy = {

        registry = "quay.io";

        repository = "cilium/cilium-envoy";

        tag = "v1.31.5-1741765102-efed3defcc70ab5b263a0fc44c93d316b846a211";

        digest = "sha256:377c78c13d2731f3720f931721ee309159e782d882251709cb0fac3b42c03f4b";

      };

      floes.cilium.images.hubbleRelay = {

        registry = "quay.io";

        repository = "cilium/hubble-relay";

        tag = "v1.17.2";

        digest = "sha256:42a8db5c256c516cacb5b8937c321b2373ad7a6b0a1e5a5120d5028433d586cc";

      };

      floes.cilium.images.certgen = {

        registry = "quay.io";

        repository = "cilium/certgen";

        tag = "v0.2.1";

        digest = "sha256:ab6b1928e9c5f424f6b0f51c68065b9fd85e2f8d3e5f21fbd1a3cb27e6fb9321";

      };

      bundles.gateway-api-crds.yamls =
        if cfg.gatewayAPI.enable then [ k8sSpecs.standaloneCrds.gateway-api ] else [ ];

      bundles.cilium.helmCharts.cilium = {
        chart = chartRef;
        releaseName = "cilium";
        namespace = "kube-system";
        values = ciliumValues;
      };
      bundles.cilium.provides = [ "cilium/cni/ready" ];
      bundles.cilium.readyProbe = {
        kind = "condition";
        resource = "daemonset/cilium";
        namespace = "kube-system";
        condition = "Available";
        timeout = "10m";
      };

      bundles.cilium-gateway.resources = optionalAttrs cfg.gatewayAPI.enable {
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

      bundles.cilium-gateway-tls.resources =
        optionalAttrs
          (cfg.gatewayAPI.enable && cfg.gatewayAPI.tls.enable && cfg.gatewayAPI.tls.domain != "")
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

      bundles.cilium-bgp.resources =
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
        if (cfg.lbIPAM.enable || cfg.bgp.enable) then poolResources // bgpResources else { };

      provisioner.k3d.autoDeployManifests =
        if config.cluster.provisioner == "k3d" then
          [
            {
              name = "cilium";
              content = ciliumAutoDeployManifest;
            }
          ]
        else
          [ ];
    };
})
  __floeModuleArgs
