{ config, lib, ... }:

let
  inherit ((import ../../../modules/lab/cluster/floe-options.nix { inherit lib; }))
    floeOptions
    ;
  inherit ((import ../../../modules/lab/lab-floe-options.nix { inherit lib; }))
    labFloeOptions
    ;

  # A lab floe declared by hand, for the same reason: the lab scope has a
  # shared option module too, and a floe that imports it directly must get the
  # same option set. What it exports is what the cluster floe below reads, so
  # this pair is the whole lab-to-cluster channel in one file.
  handwrittenLab = {
    imports = [
      (labFloeOptions { name = "handwritten-lab"; })
    ];

    options.lab.floes.handwritten-lab.exports.tenant = lib.mkOption {
      type = lib.types.str;
      description = "Something a cluster floe can ask this lab floe for.";
    };

    config = {
      lab.floes.handwritten-lab.exports.tenant = "acme";
    };
  };

  # A floe reduced to the essentials. If this file ever needs more from the library to
  # get the option set, the retargeting or an attributed bundle, then the rules
  # went back into the constructor and this fixture is the thing that says so.
  handwritten =
    {
      config,
      lib,
      pkgs,
      lab,
      ...
    }:
    {
      imports = [ (floeOptions { name = "handwritten"; }) ];

      options.floes.handwritten.replicas = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "Its own option, declared beside the ones every floe has.";
      };

      options.floes.handwritten.tenantFromLab = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        internal = true;
        default = lab.floes.handwritten-lab.exports.tenant or null;
        description = ''
          What a lab floe exports, read from cluster scope through the `lab`
          argument.

          Recorded as an option rather than used, because reading it is the
          whole point: a cluster floe could not reach a lab floe at all until
          `lab.floes` was part of that argument.
        '';
      };

      config = lib.mkIf config.floes.handwritten.enable {
        floes.handwritten.images.app = {
          repository = "nginx";
          tag = "1.29-alpine";
        };

        floes.handwritten.steps.handwritten-sync = {
          kind = "run-script";
          direction = "deploy";
          description = "A step declared under the floe rather than on the cluster";
          params.bin = "${pkgs.writeShellScriptBin "handwritten-sync" "true"}/bin/handwritten-sync";
        };

        floes.handwritten.ops.handwritten.status = {
          description = "An ops command declared under the floe";
          package = pkgs.writeShellScriptBin "handwritten-status" "true";
        };

        floes.handwritten.bundles.handwritten = {
          createNamespaces = [ config.floes.handwritten.namespace ];
          provides = [ "handwritten/app/ready" ];

          resources.app = {
            apiVersion = "apps/v1";
            kind = "Deployment";
            metadata = {
              name = "handwritten";
              namespace = config.floes.handwritten.namespace;
            };
            spec = {
              replicas = config.floes.handwritten.replicas;
              selector.matchLabels."app.kubernetes.io/name" = "handwritten";
              template = {
                metadata.labels."app.kubernetes.io/name" = "handwritten";
                spec.containers = [
                  {
                    name = "app";
                    image = config.floes.handwritten.images.app.ref;
                  }
                ];
              };
            };
          };
        };
      };
    };

  cluster = config.lab.clusters.app;
in
{
  lab.name = "handwritten-floe";
  lab.environment = "development";
  lab.dns.zone = "handwritten.test";

  lab.images.registry = "registry.example.com";

  imports = [ handwrittenLab ];

  lab.floes.handwritten-lab.enable = true;

  lab.clusters.app =
    { ... }:
    {
      imports = [ handwritten ];

      cluster.name = "app";
      cluster.provisioner = "k3d";

      floes.handwritten.enable = true;
      floes.handwritten.replicas = 2;
    };

  lab.assertions = [
    {
      assertion = cluster.floes.handwritten.namespace == "handwritten";
      message = "the shared option set did not reach a floe that declared only its own options";
    }
    {
      assertion = cluster.floes.handwritten.images.app.ref == "registry.example.com/nginx:1.29-alpine";
      message = ''
        image retargeting did not reach a hand-written floe: got
        '${cluster.floes.handwritten.images.app.ref}' rather than the lab's registry.
        Retargeting lives on the shared `images` option, so any floe that
        imports it gets it.
      '';
    }
    {
      assertion = cluster.bundles.handwritten.declaredBy == "handwritten";
      message = "a hand-written floe's bundle carries no provenance, so network policies, imageCompleteness and the SBOM would skip it";
    }
    {
      assertion = cluster.floes.handwritten.replicas == 2;
      message = "a floe's own options no longer merge with the shared ones";
    }
    {
      assertion =
        cluster.steps.handwritten-sync.origin == "clusters.app.floes.handwritten.steps.handwritten-sync";
      message = ''
        a step declared under a floe was lifted without the floe's name: got
        '${toString cluster.steps.handwritten-sync.origin}'.

        `origin` is what an anchor or cycle error quotes, so losing it here
        means those errors name the cluster and leave the floe to be guessed.
      '';
    }
    {
      assertion = cluster.ops ? handwritten && cluster.ops.handwritten ? status;
      message = "an ops command declared under a floe was not lifted into the cluster's ops";
    }
    {
      assertion = cluster.floes.handwritten.tenantFromLab == "acme";
      message = ''
        a cluster floe could not read a lab floe's exports: got
        ${builtins.toJSON cluster.floes.handwritten.tenantFromLab} rather than
        "acme".

        That channel is `lab.floes.<n>.exports`, carried into cluster scope by
        the `lab` argument. Without it a cluster floe can be told things by a
        lab floe but can never ask one anything.
      '';
    }
  ];
}
