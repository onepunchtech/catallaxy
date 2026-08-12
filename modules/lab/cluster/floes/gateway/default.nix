{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  ...
}@__floeModuleArgs:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) mkFloe refs;
  verifyTypes = import ../../../verify-types.nix { inherit lib; };
in
(mkFloe {
  name = "gateway";
  imports = [ ./options.nix ];
  exports =
    { lib, ... }:
    {
      routing = lib.mkOption {
        type = refs.mkCapability {
          publicReady = refs.tokenOption ''
            "The public Gateway is programmed and accepting routes."
            Anything emitting an HTTPRoute/GRPCRoute against it gates on
            this.
          '';
          controllerReady = refs.tokenOption ''
            "The Gateway API controller is running." Weaker than
            `publicReady`; enough to apply a Gateway, not enough for a
            route to serve traffic.
          '';
        };
        default = null;
        description = ''
          Gateway API routing, or null when this floe is off. Consumers
          assert on this rather than on `floes.gateway.enable`: the
          question is "will my HTTPRoute have a parent", which is ours.
        '';
      };

      className = lib.mkOption {
        type = lib.types.str;
        default = "traefik";
        description = "GatewayClass name.";
      };
      namespace = lib.mkOption {
        type = lib.types.str;
        default = "kube-system";
        description = "Gateway namespace.";
      };
      gatewayName = lib.mkOption {
        type = lib.types.str;
        default = "default-gateway";
        description = "Public Gateway resource name.";
      };
      passthroughEnabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the TLS passthrough listener is enabled.";
      };
      terminatingListenerName = lib.mkOption {
        type = lib.types.str;
        default = "https";
        description = ''
          Listener a plain (non-passthrough) HTTPRoute should name in
          `parentRefs.sectionName`. `https` when TLS terminates here,
          `http` when it does not: a lab with `tls.enable = false`
          has no `https` listener, so a route pinned to it attaches to
          nothing (`NoMatchingParent`) and the gateway 404s.
        '';
      };
      passthroughPort = lib.mkOption {
        type = lib.types.port;
        default = 8444;
        description = "Passthrough entryPoint port on Traefik.";
      };
      internalEnabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the internal-tier Gateway is on.";
      };
      internalGatewayName = lib.mkOption {
        type = lib.types.str;
        default = "default-gateway";
        description = ''
          Name of the Gateway resource internal-tier HTTPRoutes
          attach to. Falls back to the public gateway when the
          internal tier is disabled, so misconfigurations degrade
          gracefully.
        '';
      };
      internalExposureMode = lib.mkOption {
        type = lib.types.str;
        default = "haproxy-local";
        description = "How the internal Gateway is reachable (haproxy-local | netbird | none).";
      };
      internalGatewayClusterIP = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Pinned ClusterIP for the traefik-internal Service (netbird mode).";
      };
      internalHostnames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Registered internal-tier hostnames (deduped + sorted).";
      };
      internalDomain = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          DNS zone the internal tier is named under, or "" when there
          is no internal tier.

          Whatever resolves the internal tier claims this zone, so
          consumers read it here rather than deriving their own: netbird
          pushes exactly this to mesh peers, and CoreDNS answers it.
        '';
      };
    };
  module =
    {
      config,
      lib,
      cfg,
      k8sSpecs,
      peers,
      ...
    }:
    let
      inherit (lib) optionals optionalAttrs;
      cidrLib = import ../../../../../lib/util/network.nix { inherit lib; };

      httpPort = if cfg.controller == "traefik" then 8000 else 80;
      httpsPort = if cfg.controller == "traefik" then 8443 else 443;

      passthroughPort = if cfg.controller == "traefik" then cfg.tls.passthrough.port else 443;

      standardListeners = [
        {
          name = "http";
          protocol = "HTTP";
          port = httpPort;
          allowedRoutes.namespaces.from = "All";
        }
      ]
      ++ optionals (cfg.tls.enable && cfg.tls.domain != "") [
        {
          name = "https";
          protocol = "HTTPS";
          port = httpsPort;
          allowedRoutes.namespaces.from = "All";
          tls = {
            mode = "Terminate";

            certificateRefs = [
              { name = "gateway-tls"; }
            ]
            ++ map (
              r: { name = r.name; } // lib.optionalAttrs (r.namespace != null) { namespace = r.namespace; }
            ) cfg.tls.extraCertificateRefs;
          };
        }
      ]
      ++ optionals cfg.tls.passthrough.enable [
        {
          name = "tls-passthrough";
          protocol = "TLS";
          port = passthroughPort;
          allowedRoutes.namespaces.from = "All";
          tls.mode = "Passthrough";
        }
      ];

      publicGateway = {
        "default-gateway" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "Gateway";
          metadata = {
            name = cfg.gatewayName;
            namespace = cfg.namespace;
            labels."catallaxy.io/network-tier" = "public";
          };
          spec = {
            gatewayClassName = cfg.className;
            listeners = standardListeners;
          };
        };
      };

      internalGateway = optionalAttrs cfg.internal.enable {

        "internal-gateway" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "Gateway";
          metadata = {
            name = cfg.internal.name;
            namespace = cfg.namespace;
            labels."catallaxy.io/network-tier" = "internal";
            annotations."catallaxy.io/exposure-mode" = cfg.internal.exposureMode;
          };
          spec = {
            gatewayClassName = cfg.className;
            listeners = standardListeners;
          };
        };
      };

      internalService =
        optionalAttrs
          (
            cfg.controller == "traefik"
            && cfg.internal.enable
            && cfg.internal.exposureMode == "netbird"
            && cfg.internal.clusterIPAddress != null
          )
          {

            "traefik-internal" = {
              apiVersion = "v1";
              kind = "Service";
              metadata = {
                name = "traefik-internal";
                namespace = cfg.namespace;
                labels = {
                  "app.kubernetes.io/managed-by" = "catallaxy";
                  "catallaxy.io/network-tier" = "internal";
                };
              };
              spec = {
                type = "ClusterIP";
                clusterIP = cfg.internal.clusterIPAddress;
                selector = {
                  "app.kubernetes.io/instance" = "traefik-${cfg.namespace}";
                  "app.kubernetes.io/name" = "traefik";
                };
                ports = [
                  {
                    name = "web";
                    port = 80;
                    targetPort = "web";
                    protocol = "TCP";
                  }
                ]
                ++ optionals (cfg.tls.enable && cfg.tls.domain != "") [
                  {
                    name = "websecure";
                    port = 443;
                    targetPort = "websecure";
                    protocol = "TCP";
                  }
                ]
                ++ optionals cfg.tls.passthrough.enable [
                  {
                    name = "passthrough";
                    port = cfg.tls.passthrough.port;
                    targetPort = "passthrough";
                    protocol = "TCP";
                  }
                ];
              };
            };
          };

      externalGatewayClass = optionalAttrs (cfg.controller != "traefik") {
        "gateway-class" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "GatewayClass";
          metadata.name = cfg.className;
          spec.controllerName = cfg.controllerName;
        };
      };

      traefikHelm = optionalAttrs (cfg.controller == "traefik") {
        traefik = {
          chart = cfg.chart;
          releaseName = "traefik";
          namespace = cfg.namespace;
          values = {

            providers.kubernetesGateway = {
              enabled = true;
              experimentalChannel = true;
            };

            gateway.enabled = false;

            ingressRoute.dashboard.enabled = false;

            additionalArguments = [
              "--entryPoints.websecure.transport.respondingTimeouts.idleTimeout=0s"
              "--entryPoints.websecure.transport.respondingTimeouts.writeTimeout=0s"
              "--serversTransport.forwardingTimeouts.idleConnTimeout=0s"
              "--serversTransport.forwardingTimeouts.responseHeaderTimeout=0s"
            ];
          }

          // optionalAttrs cfg.tls.passthrough.enable {
            ports.passthrough = {
              port = cfg.tls.passthrough.port;
              expose.default = true;
              exposedPort = cfg.tls.passthrough.port;
              protocol = "TCP";
            };
          };
        };
      };

      tlsResources = optionalAttrs (cfg.tls.enable && cfg.tls.domain != "") {
        "gateway-tls-cert" = {
          apiVersion = "cert-manager.io/v1";
          kind = "Certificate";
          metadata = {
            name = "gateway-tls";
            namespace = cfg.namespace;
          };
          spec = {
            secretName = "gateway-tls";
            issuerRef = {
              name = cfg.tls.issuerRef.name;
              kind = cfg.tls.issuerRef.kind;
            };
            dnsNames = [
              cfg.tls.domain
              "*.${cfg.tls.domain}"
            ]
            ++ lib.optionals (cfg.internal.enable && cfg.internal.domain != "") [
              cfg.internal.domain
              "*.${cfg.internal.domain}"
            ];
          };
        };

        "http-to-https-redirect" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            name = "http-to-https-redirect";
            namespace = cfg.namespace;

            annotations."external-dns.alpha.kubernetes.io/controller" = "none";
          };
          spec = {
            parentRefs = [
              {
                name = cfg.gatewayName;
                namespace = cfg.namespace;
                sectionName = "http";
              }
            ];
            hostnames = [ "*.${cfg.tls.domain}" ];
            rules = [
              {
                filters = [
                  {
                    type = "RequestRedirect";
                    requestRedirect = {
                      scheme = "https";
                      statusCode = 301;
                    };
                  }
                ];
              }
            ];
          };
        };
      };
    in
    {

      floes.gateway.drift.expected = lib.optionals (cfg.controller == "traefik") [
        {
          group = "gateway.networking.k8s.io";
          kinds = [
            "Gateway"
            "HTTPRoute"
          ];
          managedBy = [ "traefik" ];
          reason = "traefik defaults listener/backendRef fields on the Gateway and HTTPRoute objects it admits.";
        }
      ];

      floes.gateway.exports = {
        routing = {
          publicReady = "gateway/public/ready";
          controllerReady = "gateway/controller/ready";
        };
        inherit (cfg) className gatewayName;
        namespace = cfg.namespace;
        passthroughEnabled = cfg.tls.passthrough.enable;
        passthroughPort = cfg.tls.passthrough.port;

        terminatingListenerName = if (cfg.tls.enable && cfg.tls.domain != "") then "https" else "http";

        internalEnabled = cfg.internal.enable;
        internalGatewayName = if cfg.internal.enable then cfg.internal.name else cfg.gatewayName;
        internalExposureMode = cfg.internal.exposureMode;
        internalGatewayClusterIP = cfg.internal.clusterIPAddress;

        internalHostnames = lib.unique (lib.sort lib.lessThan cfg.internalHostnames);
        internalDomain = if cfg.internal.enable then cfg.internal.domain else "";
      };

      floes.gateway.verify.gateways-programmed = {
        description = "Every Gateway was programmed, so something is actually listening";
        reject = [
          {
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "Gateway";
            metadata.namespace = cfg.namespace;
            ${verifyTypes.conditionIsNot { type = "Programmed"; }} = true;
          }
        ];
      };

      assertions = [

        {
          assertion = !(cfg.tls.enable && cfg.tls.domain != "") || (peers.cert-manager.issuance != null);
          message = "gateway tls.enable requires floes.cert-manager to be enabled (reconciles the wildcard Certificate CR).";
        }
        {
          assertion =
            !(cfg.internal.enable && cfg.internal.exposureMode == "netbird")
            || cfg.internal.clusterIPAddress != null;
          message = ''
            floes.gateway.internal.clusterIPAddress must be set
            when internal.exposureMode = "netbird". Pick an IP inside
            the cluster's service CIDR but outside the kube-allocated
            range (convention: `<cidr-base>.250`). Required so
            internal-tier hostnames have a mesh-reachable address.
          '';
        }

        {
          assertion =
            cfg.internal.clusterIPAddress == null
            || cidrLib.ipInCidr cfg.internal.clusterIPAddress config.cluster.network.serviceSubnet;
          message = ''
            floes.gateway.internal.clusterIPAddress
            (${toString cfg.internal.clusterIPAddress}) is not inside
            cluster.network.serviceSubnet
            (${config.cluster.network.serviceSubnet}). The apiserver
            will reject the Service create with `failed to allocate
            IP: not in valid range`. Update clusterIPAddress to fall
            within the service subnet.
          '';
        }
      ];

      bundles.gateway-api-crds = {
        owner = {
          bootstrap = "install-target";
          steady = "argocd";
        };
        yamls = [ k8sSpecs.standaloneCrds.gateway-api ];
        provides = [ "gateway-api/crds/established" ];
      };

      bundles.gateway-controller.owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };
      bundles.gateway-controller.helmCharts = traefikHelm;
      bundles.gateway-controller.resources = externalGatewayClass;

      bundles.gateway-controller.requires = [
        "gateway-api/crds/established"
      ];
      bundles.gateway-controller.provides = [
        "gateway/controller/ready"
      ];
      bundles.gateway-controller.readyProbe = {
        kind = "condition";
        resource = "deployment/traefik";
        namespace = cfg.namespace;
        condition = "Available";
        timeout = "5m";
      };

      bundles.gateway.owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };
      bundles.gateway.resources = publicGateway // internalGateway // internalService;
      bundles.gateway.requires = [
        "gateway/controller/ready"
      ];
      bundles.gateway.provides = [
        "gateway/public/ready"
      ];

      bundles.gateway.readyProbe = {
        kind = "jsonpath";
        resource = "gateway/${cfg.gatewayName}";
        namespace = cfg.namespace;
        jsonpath = "{.status.addresses[0].value}";

        timeout = "10m";
      };

      bundles.gateway-tls.owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };
      bundles.gateway-tls.resources = tlsResources;

      bundles.gateway-tls.requires = [
        "gateway/public/ready"
      ];
      bundles.gateway-tls.provides = [
        "gateway/tls/ready"
      ];

      bundles.gateway-tls.readyProbe = {
        kind = "condition";
        resource = "certificate/gateway-tls";
        namespace = cfg.namespace;
        condition = "Ready";
        timeout = "15m";
      };
    };
})
  __floeModuleArgs
