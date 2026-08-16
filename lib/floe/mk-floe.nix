{ lib }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    optionalAttrs
    ;

  inherit (import ../../modules/lab/cluster/lib/kubernetes/drift.nix { inherit lib; }) driftEntryType;
in
{

  mkFloe =
    {
      name,
      version ? null,
      exports ? { },
      requires ? [ ],

      drift ? [ ],
      options ? { },
      imports ? [ ],
      module,
    }:
    let

      exportsToOptions =
        p:
        if builtins.isFunction p then

          args: { options = p args; }
        else

          { options = p; };
      exportsType = types.submodule (exportsToOptions exports);

      normaliseOptions = o: if builtins.isFunction o then o { inherit lib; } else o;

      overridesOptions = {
        extraAnnotations = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = ''
            Extra annotations merged onto every resource this floe
            emits. Cloud-provider-specific hooks (e.g., AWS
            `service.beta.kubernetes.io/aws-load-balancer-*`) go here
            rather than in the floe's module body.
          '';
        };
        extraLabels = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Extra labels merged onto every resource this floe emits.";
        };
        serviceType = mkOption {
          type = types.enum [
            "ClusterIP"
            "NodePort"
            "LoadBalancer"
          ];
          default = "ClusterIP";
          description = ''
            Default Service type for any Service this floe emits.
            Downstream users can lift this to `LoadBalancer` for
            cloud-provider integration without editing the floe.
          '';
        };
        nodeSelector = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Extra nodeSelector merged onto workload pod templates.";
        };
        tolerations = mkOption {
          type = types.listOf types.attrs;
          default = [ ];
          description = "Extra tolerations appended to workload pod templates.";
        };
      };
    in
    moduleArgs@{
      config,
      lib,
      pkgs,
      cataCharts ? null,
      k8sSpecs ? null,
      k8sHelpers ? null,
      # Not optional. The module system passes arguments by the formals each
      # floe file declares, so a floe that does not name `lab` would silently
      # get retargeting that does nothing. Failing to evaluate is the only
      # way that stays noticed.
      lab,
      ...
    }:
    let
      cfg = config.floes.${name};

      imageTypes = import ../../modules/lab/image-types.nix { inherit lib; };

      labImages = lab.images or { };

      peers = lib.mapAttrs (_: floeCfg: floeCfg.exports or { }) (
        builtins.removeAttrs config.floes [ name ]
      );
    in
    {

      inherit imports;

      options.floes.${name} = {
        enable = mkEnableOption "the ${name} floe";

        verify = mkOption {
          type = types.attrsOf (import ../../modules/lab/verify-types.nix { inherit lib; }).checkType;
          default = { };
          description = ''
            Assertions this floe makes about itself once it is running,
            collected into the lab's `cata lab verify` run.

            The component knows what working means for itself, so it says so
            once here rather than in every lab that enables it. This is the
            live counterpart to `readyProbe`: that one gates the install
            wave, this one answers "is it still right".
          '';
        };

        lint = mkOption {
          type = types.attrsOf (import ../../modules/lab/lint-types.nix { inherit lib; }).checkType;
          default = { };
          description = ''
            Checks this floe makes about its own rendered manifests, run on
            every cluster the floe is enabled on.

            The static counterpart to `verify`: lint reads what was rendered
            and needs no cluster, verify reads a running one.
          '';
        };

        images = mkOption {
          type = types.attrsOf imageTypes.imageType;
          default = { };
          apply = imageTypes.retarget {
            registry = labImages.registry or null;
            pinned = labImages.pinned.${name} or { };
          };
          description = ''
            Every image this floe needs, including the ones its chart pulls,
            keyed by a label that is part of the floe's interface.

            A floe wrapper is curated the way a chart is: declaring the images
            is what says this combination was tested, and it is what gives a
            consumer something to override. Read `cfg.images.<label>.ref`
            rather than writing a reference by hand.

            What is read back is what the lab settled on, not only what the
            floe wrote: `lab.images.registry` and `lab.images.pinned.${name}`
            are folded in here, so a floe gets retargeting without knowing it
            exists.
          '';
        };

        imagesComplete = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether `images` names every image this floe renders, chart ones
            included. When true, a check scrapes what the floe actually
            renders and fails naming anything undeclared.

            Off by default so a floe part-way through declaring is not a
            build failure. Turning it on is the floe saying its image set is
            the whole set.
          '';
        };

        network = mkOption {
          type = (import ../../modules/lab/network-policy-types.nix { inherit lib; }).networkType;
          default = { };
          description = ''
            Traffic this floe needs, as intent rather than as policy, used
            when a cluster turns `security.networkPolicies` on.

            Both halves of a cross-floe flow are declared, one by each floe,
            because a default-deny namespace refuses in both directions and a
            rule written at only one end is traffic that silently does not
            flow. An assertion pairs them up.
          '';
        };

        namespace = mkOption {
          type = types.str;
          default = name;
          description = "Kubernetes namespace the floe deploys into.";
        };

        version = mkOption {
          type = types.nullOr types.str;
          default = version;
          description = "Version of the packaged software (informational).";
        };

        exports = mkOption {
          type = exportsType;
          default = { };
          description = ''
            The typed interface this floe exposes to downstream floes.
            Consumers read specific fields (e.g.
            `config.floes.${name}.exports.<field>`) with autocomplete
            and eval-time validation, instead of untyped `ref` attrs.

            Not to be confused with a bundle's `provides`, which is a
            list of readiness tokens for the install DAG.
          '';
        };

        drift.expected = mkOption {
          type = types.listOf driftEntryType;
          default = drift;
          description = ''
            Drift this floe expects on its own resources.

            Writable, unlike `requires`; an operator who hits a manager
            name the floe author did not anticipate can append here
            without forking the floe, the same escape-hatch reasoning as
            `overrides`. Aggregated into
            `cluster.drift.declarations.<floe>` when the floe is enabled.
          '';
        };

        requires = mkOption {
          type = types.listOf types.str;
          default = requires;
          readOnly = true;
          description = ''
            Names of floes this floe depends on. Introspection only,
            the actual assertion emission is wired at the mkFloe seam
            (see the `config` block below). Exposed so tooling and
            downstream tests can see the dependency graph without
            re-importing the floe module.
          '';
        };

        overrides = mkOption {
          type = types.submodule { options = overridesOptions; };
          default = { };
          description = ''
            Standard escape hatch for provider-specific customizations.
            Every floe carries this: annotations, labels, service types,
            node selectors, so provider assumptions do not leak into
            the floe's module body.
          '';
        };

      }
      // (normaliseOptions options);

      config = mkIf cfg.enable (
        let
          moduleOutput = module (moduleArgs // { inherit cfg peers; });
          provenance = import ./bundle-provenance.nix { inherit lib; };
        in
        lib.mkMerge (
          [
            moduleOutput
            (provenance.stampFloe { inherit name moduleOutput; })
          ]
          ++ lib.optional (requires != [ ]) {
            assertions = map (req: {
              assertion = (config.floes.${req} or { }).enable or false;
              message = "floe '${name}' requires floe '${req}' to be enabled";
            }) requires;
          }
        )
      );
    };
}
