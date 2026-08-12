{
  config,
  lib,
  pkgs,
  lab,
  ...
}:
let
  dns = lab.dns;
  planTokens = import ../../../../lib/plan-tokens.nix { inherit lib; };
in
{
  cluster.name = "core";
  cluster.kubernetes = {
    distribution = "k3s";
    controlPlanes = 1;
    workers = 0;
  };

  floes.cert-manager = {
    enable = true;
    selfSignedCA.enable = true;
  };

  floes.gateway = {
    enable = true;
    tls = {
      enable = true;
      domain = dns.zone;
      issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
    };
  };

  floes.reloader.enable = true;

  secrets.projections.session-key = {
    source = "session-key";
    namespace = "podinfo";
    keys.secret.from = "secret";
  };

  verify.checks.session-key-projected = {
    description = "The generated session key was projected into the cluster";
    expect = {
      apiVersion = "v1";
      kind = "Secret";
      metadata = {
        name = "session-key";
        namespace = "podinfo";
      };
    };
  };

  steps.check-session-key = {
    kind = "run-script";
    direction = "deploy";
    description = "Check the generated session key reached the preflight environment";
    provides = [ planTokens.lab.preflightOk ];
    before = planTokens.wantsAll [
      planTokens.lab.services
    ];
    params = {
      bin = "${
        pkgs.writeShellApplication {
          name = "check-session-key";
          text = ''
            if [ -z "''${SESSION_KEY:-}" ]; then
              echo "SESSION_KEY was not injected from the managed secret" >&2
              exit 1
            fi
            echo "session key reached the hook (''${#SESSION_KEY} chars)"
          '';
        }
      }/bin/check-session-key";
      env = [
        {
          name = "SESSION_KEY";
          secret = "session-key";
          key = "secret";
        }
      ];
    };
  };

  floes.cnpg = {
    enable = true;
    clusters.postgres = {
      namespace = "forgejo";
      createNamespace = true;
      instances = 1;
      storage.size = "1Gi";
      postgresql.version = "16";
    };
  };

  floes.forgejo = {
    enable = true;
    domain = "git.${dns.zone}";
    tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
    database = {
      host = config.floes.cnpg.clusters.postgres.ref.host;
      name = "app";
      user = "app";
      secretRef = {
        name = "postgres-app";
        key = "password";
      };
    };
  };

  floes.argocd = {
    enable = true;
    domain = "argocd.${dns.zone}";
    tls.issuerRef = config.floes.cert-manager.exports.defaultIssuerRef;
  };

  bundles.coredns-lab-dns.resources = lib.mkIf dns.enable {
    coredns-custom = {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = {
        name = "coredns-custom";
        namespace = "kube-system";
      };
      data = {
        "lab.server" = ''
          ${dns.zone}:53 {
            errors
            cache 30
            forward . ${dns.server}:${toString dns.port}
          }
        '';
      };
    };
  };

  floes.custom.enable = true;
  floes.custom.apps.podinfo = {
    namespace = "podinfo";

    gateway = {
      enable = true;
      domain = "podinfo.${dns.zone}";
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
          replicas = 1;
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
}
