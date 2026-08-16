{ mkFloe, lib }:

mkFloe {
  name = "my-floe";
  version = "0.1.0";

  imports = [ ./options.nix ];

  exports =
    { lib, ... }:
    {
      url = lib.mkOption {
        type = lib.types.str;
        default = "http://my-floe.my-floe.svc.cluster.local";
        description = "In-cluster URL of the Service.";
      };
    };

  module =
    { cfg, ... }:
    let
      selector."app.kubernetes.io/name" = "my-floe";
    in
    {
      floes.my-floe.exports.url = "http://my-floe.${cfg.namespace}.svc.cluster.local";

      bundles.my-floe = {
        createNamespaces = [ cfg.namespace ];

        readyProbe = {
          kind = "condition";
          resource = "deployment/my-floe";
          namespace = cfg.namespace;
          condition = "Available";
          timeout = "2m";
        };

        resources = {
          my-floe-deployment = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "my-floe";
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
                      name = "my-floe";
                      image = cfg.image;
                      ports = [ { containerPort = 80; } ];
                    }
                  ];
                };
              };
            };
          };

          my-floe-service = {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "my-floe";
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
                  targetPort = 80;
                }
              ];
            };
          };
        };
      };
    };
}
