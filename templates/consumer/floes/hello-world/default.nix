{ floeOptions, lib }:

{ config, ... }:

let
  cfg = config.floes.hello-world;

  selector."app.kubernetes.io/name" = "hello-world";
  gateway = config.floes.gateway.exports;
in
{
  imports = [
    (floeOptions {
      name = "hello-world";
      version = "1.0.0";
    })
    ./options.nix
  ];

  options.floes.hello-world.exports.url = lib.mkOption {
    type = lib.types.str;
    default = "http://hello-world.hello-world.svc.cluster.local";
    description = "In-cluster URL of the Service.";
  };

  config = lib.mkIf cfg.enable {
    floes.hello-world.exports.url = "http://hello-world.${cfg.namespace}.svc.cluster.local";

    floes.hello-world.bundles.hello-world = {
      createNamespaces = [ cfg.namespace ];

      requires = [ "gateway/controller/ready" ];
      readyProbe = {
        kind = "condition";
        resource = "deployment/hello-world";
        namespace = cfg.namespace;
        condition = "Available";
        timeout = "2m";
      };

      resources = {
        hello-deployment = {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            name = "hello-world";
            namespace = cfg.namespace;
            labels = selector // cfg.overrides.extraLabels;
            annotations = cfg.overrides.extraAnnotations;
          };
          spec = {
            replicas = cfg.replicas;
            selector.matchLabels = selector;
            template = {
              metadata.labels = selector // cfg.overrides.extraLabels;
              spec = {
                nodeSelector = cfg.overrides.nodeSelector;
                tolerations = cfg.overrides.tolerations;
                containers = [
                  {
                    name = "hello";
                    image = cfg.image;
                    args = [ "-text=${cfg.message}" ];
                    ports = [ { containerPort = 5678; } ];
                  }
                ];
              };
            };
          };
        };

        hello-service = {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            name = "hello-world";
            namespace = cfg.namespace;
            labels = cfg.overrides.extraLabels;
            annotations = cfg.overrides.extraAnnotations;
          };
          spec = {
            type = cfg.overrides.serviceType;
            inherit selector;
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
            labels = cfg.overrides.extraLabels;
            annotations = cfg.overrides.extraAnnotations;
          };
          spec = {
            hostnames = [ cfg.domain ];
            parentRefs = [
              {
                name = gateway.gatewayName;
                namespace = gateway.namespace;
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
    };
  };
}
