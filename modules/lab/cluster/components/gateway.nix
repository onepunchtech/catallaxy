# modules/cluster/components/gateway.nix
#
# Standalone Gateway API component — CNI-agnostic.
#
# Installs Gateway API CRDs, deploys a gateway controller (Traefik v3 by
# default), and creates the default GatewayClass + Gateway.
# When using Cilium with gatewayAPI.enable, you typically don't need this
# component since Cilium provides its own gateway setup.

{
  config,
  lib,
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
    optionals
    optionalAttrs
    ;
  cfg = config.components.gateway;
in
{
  options.components.gateway = {
    enable = mkEnableOption "Gateway API (standalone, CNI-agnostic)";

    controller = mkOption {
      type = types.enum [
        "traefik"
        "external"
      ];
      default = "traefik";
      description = ''
        Gateway controller to deploy:
        - traefik: deploy Traefik v3 (default, good for k3d labs)
        - external: skip controller deployment (use with Cilium or pre-installed controller)
      '';
    };

    controllerName = mkOption {
      type = types.str;
      default = "traefik.io/gateway-controller";
      description = "Gateway controller name for the GatewayClass";
    };

    className = mkOption {
      type = types.str;
      default = "traefik";
      description = "GatewayClass name";
    };

    gatewayName = mkOption {
      type = types.str;
      default = "default-gateway";
      description = "Gateway resource name (components reference this via gateway.gatewayRef)";
    };

    namespace = mkOption {
      type = types.str;
      default = "kube-system";
      description = "Namespace for the Gateway resource";
    };

    chart = mkOption {
      type = types.package;
      default = cataCharts.traefik.chart;
      description = "Traefik Helm chart derivation";
    };

    tls = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable HTTPS listener with cert-manager TLS";
      };

      issuerRef = mkOption {
        type = types.submodule {
          options = {
            name = mkOption { type = types.str; };
            kind = mkOption {
              type = types.str;
              default = "ClusterIssuer";
            };
          };
        };
        default = {
          name = "lab-ca";
          kind = "ClusterIssuer";
        };
      };

      domain = mkOption {
        type = types.str;
        default = "";
        description = "Base domain for wildcard cert (e.g. homelab.test)";
      };

      passthrough = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable TLS passthrough listener (for backends that terminate TLS themselves)";
        };
        port = mkOption {
          type = types.port;
          default = 8444;
          description = "Traefik entryPoint port for TLS passthrough (must differ from websecure port)";
        };
      };
    };

    ref = mkOption {
      type = types.attrs;
      readOnly = true;
    };
  };

  config = lib.mkMerge [
    {
      components.gateway.ref = {
        className = cfg.className;
        namespace = cfg.namespace;
        gatewayName = cfg.gatewayName;
        passthroughEnabled = cfg.tls.passthrough.enable;
        passthroughPort = cfg.tls.passthrough.port;
      };
    }

    (mkIf cfg.enable {
      # Gateway API CRDs (experimental channel for TLSRoute support)
      phases.crds.bundles.gateway-api-crds.yamls = [
        k8sSpecs.standaloneCrds.gateway-api
      ];

      # Deploy Traefik v3 as gateway controller
      phases.networking.bundles.gateway-controller.helmCharts.traefik =
        mkIf (cfg.controller == "traefik")
          {
            chart = cfg.chart;
            releaseName = "traefik";
            namespace = cfg.namespace;
            values = {
              # Gateway API provider with experimental channel (TLSRoute support)
              providers.kubernetesGateway = {
                enabled = true;
                experimentalChannel = true;
              };
              # Disable auto-created gateway — we create our own
              gateway.enabled = false;
              # Disable the default IngressRoute dashboard
              ingressRoute.dashboard.enabled = false;
            }
            # Dedicated entryPoint for TLS passthrough (separate from websecure to avoid conflicts)
            // optionalAttrs cfg.tls.passthrough.enable {
              ports.passthrough = {
                port = cfg.tls.passthrough.port;
                expose.default = true;
                exposedPort = cfg.tls.passthrough.port;
                protocol = "TCP";
              };
            };
          };

      # GatewayClass (only when not using Traefik, which creates its own)
      phases.networking.bundles.gateway-controller.resources = mkIf (cfg.controller != "traefik") {
        "gateway-class" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "GatewayClass";
          metadata.name = cfg.className;
          spec.controllerName = cfg.controllerName;
        };
      };

      # Gateway resource (in networking phase alongside the controller)
      phases.networking.bundles.gateway.resources = {
        "default-gateway" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "Gateway";
          metadata = {
            name = cfg.gatewayName;
            namespace = cfg.namespace;
          };
          spec = {
            gatewayClassName = cfg.className;
            listeners =
              let
                # Traefik uses internal entryPoint ports (8000/8443), not service ports (80/443).
                # Gateway listener ports must match entryPoint ports for Traefik to accept them.
                httpPort = if cfg.controller == "traefik" then 8000 else 80;
                httpsPort = if cfg.controller == "traefik" then 8443 else 443;
                # Passthrough MUST be on a separate port from httpsPort to avoid
                # Traefik terminating TLS before checking TLSRoutes.
                passthroughPort = if cfg.controller == "traefik" then cfg.tls.passthrough.port else 443;
              in
              [
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
                    certificateRefs = [ { name = "gateway-tls"; } ];
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
          };
        };
      };

      # Gateway TLS wildcard certificate
      phases.networking.bundles.gateway-tls.resources = mkIf (cfg.tls.enable && cfg.tls.domain != "") {
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
            ];
          };
        };

        # HTTP → HTTPS redirect for all domains on this gateway
        "http-to-https-redirect" = {
          apiVersion = "gateway.networking.k8s.io/v1";
          kind = "HTTPRoute";
          metadata = {
            name = "http-to-https-redirect";
            namespace = cfg.namespace;
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
    })
  ];
}
