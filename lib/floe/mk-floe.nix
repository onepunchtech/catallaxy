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
      ...
    }:
    let
      cfg = config.floes.${name};

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
        lib.mkMerge (
          [ (module (moduleArgs // { inherit cfg peers; })) ]
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
