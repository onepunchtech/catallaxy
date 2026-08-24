{
  config,
  lib,
  pkgs,
  cataCharts,
  k8sSpecs,
  k8sHelpers,
  lab,
  ...
}:

let
  inherit ((import ../../../../../lib/floe { inherit lib; })) floeOptions refs;

  secretReloadAnnotation = "secret.reloader.stakater.com/reload";
  configMapReloadAnnotation = "configmap.reloader.stakater.com/reload";

  cfg = config.floes.reloader;
in
{
  imports = [
    (floeOptions { name = "reloader"; })
    ./options.nix
  ];

  options.floes.reloader.exports = {
    watching = lib.mkOption {
      type = refs.mkCapability {
        ready = refs.tokenOption ''"The reloader controller is watching and will roll annotated workloads."'';
      };
      default = null;
      description = ''
        Workload reload-on-rotation, or null when this floe is off.
        Consumers that annotate for reload gate on this rather than
        naming `reloader/watching` themselves.
      '';
    };
    secretReloadAnnotation = lib.mkOption {
      type = lib.types.str;

      default = secretReloadAnnotation;
      description = ''
        The pod-template annotation key reloader watches for Secret
        references. Value should be a comma-separated list of Secret
        names in the same namespace as the workload.
      '';
    };
    configMapReloadAnnotation = lib.mkOption {
      type = lib.types.str;
      default = configMapReloadAnnotation;
      description = ''
        The pod-template annotation key reloader watches for
        ConfigMap references. Value should be a comma-separated list
        of ConfigMap names in the same namespace as the workload.
      '';
    };
    mkPatches = lib.mkOption {

      type = lib.types.raw;

      default = _workloads: [ ];
      description = ''
        Kustomize strategic-merge patch constructor. Takes a list of
        workload references and returns patch entries suitable for a
        Helm chart's `kustomize.patches`. Signature:

          [ { kind :: "Deployment"|"StatefulSet"|"DaemonSet";
              name :: str;
              secrets ? [ str ];
              configMaps ? [ str ]; } ]
          → [ kustomizePatchEntry ]

        Mirrors `lib/util/kapp.nix::mkPreserveRuntimePatches` so both
        compose in the same list.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    floes.reloader.exports = {
      watching.ready = "reloader/watching";
      inherit secretReloadAnnotation configMapReloadAnnotation;

      mkPatches =
        workloads:
        map (
          w:
          let
            annotations =
              lib.optionalAttrs (w.secrets or [ ] != [ ]) {
                ${secretReloadAnnotation} = lib.concatStringsSep "," w.secrets;
              }
              // lib.optionalAttrs (w.configMaps or [ ] != [ ]) {
                ${configMapReloadAnnotation} = lib.concatStringsSep "," w.configMaps;
              };
          in
          {
            target = { inherit (w) kind name; };
            patch = builtins.toJSON {
              apiVersion = "apps/v1";
              inherit (w) kind;
              metadata = {
                inherit (w) name;
                inherit annotations;
              };
            };
          }
        ) workloads;
    };

    floes.reloader.network = {

      declared = true;

    };

    floes.reloader.imagesComplete = true;

    floes.reloader.images.controller = {

      registry = "ghcr.io";

      repository = "stakater/reloader";

      tag = "v1.4.19";

    };

    floes.reloader.bundles.reloader = {

      owner = {
        bootstrap = "install-target";
        steady = "argocd";
      };

      includeInBootstrap = false;
      helmCharts.reloader = {
        chart = cfg.chart;
        releaseName = "reloader";
        namespace = cfg.namespace;
        values = {
          reloader = {

            watchGlobally = true;

            reloadOnCreate = true;

          };
        };
      };
      createNamespaces = [ cfg.namespace ];

      provides = [
        "reloader/watching"
        "config-reload/ready"
      ];
      readyProbe = {
        kind = "condition";
        resource = "deployment/reloader-reloader";
        namespace = cfg.namespace;
        condition = "Available";
        timeout = "3m";
      };
    };
  };
}
