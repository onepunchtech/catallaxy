# Custom component — deploys a hello-world app
#
# This shows the component pattern: declare options, write to phases.bundles.
# The bundle type (resources, helmCharts, yamls, createNamespaces) is the
# stable contract between components and the rendering pipeline.
{
  config,
  lib,
  ...
}:
let
  cfg = config.components.hello-world;
in
{
  # ─── Options ──────────────────────────────────────────────────────────
  options.components.hello-world = {
    enable = lib.mkEnableOption "hello-world demo app";

    phase = lib.mkOption {
      type = lib.types.str;
      default = "apps";
      description = "Deployment phase";
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "hello-world";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      description = "Public domain for the app";
    };

    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };

    # Computed references — other components can read these
    ref = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
    };
  };

  # ─── Config ───────────────────────────────────────────────────────────
  config = lib.mkMerge [
    {
      components.hello-world.ref = {
        namespace = cfg.namespace;
        serviceName = "hello-world";
        url = "http://hello-world.${cfg.namespace}.svc.cluster.local";
      };
    }

    (lib.mkIf cfg.enable {
      phases.${cfg.phase}.bundles.hello-world = {
        # Typed Kubernetes resources
        resources = {
          hello-deployment = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "hello-world";
              namespace = cfg.namespace;
              labels."app.kubernetes.io/name" = "hello-world";
            };
            spec = {
              replicas = cfg.replicas;
              selector.matchLabels."app.kubernetes.io/name" = "hello-world";
              template = {
                metadata.labels."app.kubernetes.io/name" = "hello-world";
                spec.containers = [
                  {
                    name = "hello";
                    image = "hashicorp/http-echo:latest";
                    args = [ "-text=Hello from catallaxy!" ];
                    ports = [ { containerPort = 5678; } ];
                  }
                ];
              };
            };
          };

          hello-service = {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "hello-world";
              namespace = cfg.namespace;
            };
            spec = {
              selector."app.kubernetes.io/name" = "hello-world";
              ports = [
                {
                  port = 80;
                  targetPort = 5678;
                }
              ];
            };
          };

          hello-route = {
            apiVersion = "gateway.networking.k8s.io/v1";
            kind = "HTTPRoute";
            metadata = {
              name = "hello-world";
              namespace = cfg.namespace;
            };
            spec = {
              hostnames = [ cfg.domain ];
              parentRefs = [
                {
                  name = "default-gateway";
                  namespace = "kube-system";
                }
              ];
              rules = [
                {
                  matches = [
                    {
                      path = {
                        type = "PathPrefix";
                        value = "/";
                      };
                    }
                  ];
                  backendRefs = [
                    {
                      name = "hello-world";
                      port = 80;
                    }
                  ];
                }
              ];
            };
          };
        };

        createNamespaces = [ cfg.namespace ];
      };
    })
  ];
}
