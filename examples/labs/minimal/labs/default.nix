{ lib, ... }:
{
  lab.name = lib.mkDefault "minimal";
  lab.dns.zone = lib.mkDefault "minimal.test";

  # Every image this lab renders is rewritten to the digest recorded beside
  # it, so requiring one is something the lab can actually satisfy. Refresh
  # with `cata images lock --name minimal.local --out
  # examples/labs/minimal/images.lock.json` after bumping anything it pulls.
  lab.images.lockFile = ../images.lock.json;
  lab.images.requireDigest = true;

  lab.clusters.app =

    { lab, ... }:
    {
      cluster.name = "app";
      cluster.kubernetes = {
        distribution = "k3s";
        controlPlanes = 1;
        workers = 0;
      };

      floes.gateway.enable = true;

      floes.custom.enable = true;
      floes.custom.apps.podinfo = {
        namespace = "podinfo";

        gateway = {
          enable = true;
          domain = "podinfo.${lab.dns.zone}";
          serviceName = "podinfo";
          servicePort = 80;
        };

        resources = {
          podinfo-deployment = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "podinfo";
              namespace = "podinfo";
            };
            spec = {
              replicas = 2;
              selector.matchLabels."app.kubernetes.io/name" = "podinfo";
              template = {
                metadata.labels."app.kubernetes.io/name" = "podinfo";
                spec.containers = [
                  {
                    name = "podinfo";
                    image = "ghcr.io/stefanprodan/podinfo:6.7.1";
                    ports = [
                      {
                        name = "http";
                        containerPort = 9898;
                      }
                    ];

                    readinessProbe = {
                      httpGet = {
                        path = "/readyz";
                        port = 9898;
                      };
                      initialDelaySeconds = 2;
                    };
                    livenessProbe = {
                      httpGet = {
                        path = "/healthz";
                        port = 9898;
                      };
                      initialDelaySeconds = 5;
                    };
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "32Mi";
                      };
                      limits.memory = "128Mi";
                    };
                  }
                ];
              };
            };
          };

          podinfo-service = {
            apiVersion = "v1";
            kind = "Service";
            metadata = {
              name = "podinfo";
              namespace = "podinfo";
            };
            spec = {
              selector."app.kubernetes.io/name" = "podinfo";
              ports = [
                {
                  name = "http";
                  port = 80;
                  targetPort = 9898;
                }
              ];
            };
          };
        };
      };
    };
}
