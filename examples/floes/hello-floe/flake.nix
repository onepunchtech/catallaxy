{
  description = "hello-floe: a minimal external floe demonstrating the mkFloe API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    catallaxy.url = "path:../../..";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      catallaxy,
      nixpkgs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake.floes.hello = catallaxy.lib.floe.mkFloe {
        name = "hello";
        version = "1.29-alpine";

        exports =
          { lib, ... }:
          {
            url = lib.mkOption {
              type = lib.types.str;
              description = "In-cluster URL of the nginx Service.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              default = 80;
            };
          };

        options =
          { lib, ... }:
          {
            image = lib.mkOption {
              type = lib.types.str;
              default = "nginx:1.29-alpine";
              description = "Container image to run.";
            };
            replicas = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1;
              description = "Number of replicas.";
            };
          };

        module =
          {
            config,
            lib,
            cfg,
            ...
          }:
          {
            bundles.hello.resources = {
              hello-deployment = {
                apiVersion = "apps/v1";
                kind = "Deployment";
                metadata = {
                  name = "hello";
                  namespace = cfg.namespace;
                  labels = {
                    "app.kubernetes.io/name" = "hello";
                  }
                  // cfg.overrides.extraLabels;
                  annotations = cfg.overrides.extraAnnotations;
                };
                spec = {
                  replicas = cfg.replicas;
                  selector.matchLabels."app.kubernetes.io/name" = "hello";
                  template = {
                    metadata.labels = {
                      "app.kubernetes.io/name" = "hello";
                    }
                    // cfg.overrides.extraLabels;
                    spec = {
                      nodeSelector = cfg.overrides.nodeSelector;
                      tolerations = cfg.overrides.tolerations;
                      containers = [
                        {
                          name = "nginx";
                          image = cfg.image;
                          ports = [ { containerPort = cfg.exports.port; } ];
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
                  name = "hello";
                  namespace = cfg.namespace;
                  labels = cfg.overrides.extraLabels;
                  annotations = cfg.overrides.extraAnnotations;
                };
                spec = {
                  type = cfg.overrides.serviceType;
                  selector."app.kubernetes.io/name" = "hello";
                  ports = [
                    {
                      port = cfg.exports.port;
                      targetPort = cfg.exports.port;
                    }
                  ];
                };
              };
            };

            floes.hello.exports = {
              url = "http://hello.${cfg.namespace}.svc.cluster.local:${toString cfg.exports.port}";

            };
          };
      };

      perSystem =
        { system, pkgs, ... }:
        {
          checks = {

            floe-hello-isolation =
              let
                lib = pkgs.lib;
                inherit (catallaxy.lib.floe) evalFloe;
                result = evalFloe {
                  floe = self.floes.hello;
                  cluster = {
                    floes.hello.enable = true;
                  };
                };
                deploymentCount = builtins.length (lib.attrNames (result.manifests.hello.resources or { }));
              in
              pkgs.runCommand "floe-hello-isolation" { } ''
                cat <<EOF > $out
                hello-floe emitted ${toString deploymentCount} resource(s)
                url = ${result.exports.url}
                EOF
                if [ ${toString deploymentCount} -ne 2 ]; then
                  echo "expected 2 resources (Deployment + Service), got ${toString deploymentCount}" >&2
                  exit 1
                fi
                if [ "${result.exports.url}" != "http://hello.hello.svc.cluster.local:80" ]; then
                  echo "unexpected exports.url: ${result.exports.url}" >&2
                  exit 1
                fi
              '';
          };
        };
    };
}
