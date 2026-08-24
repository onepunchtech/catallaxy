{ lib }:

let
  inherit (lib) mkOption mkEnableOption types;

  imageTypes = import ../image-types.nix { inherit lib; };
  k8sLib = import ./lib/kubernetes/types.nix { inherit lib; };
  inherit (import ./lib/kubernetes/drift.nix { inherit lib; }) driftEntryType;
  inherit (import ../planner/types.nix { inherit lib; }) clusterStepType;
  infraTypes = import ../../../lib/infra/types.nix { inherit lib; };
  inherit (import ./secrets-generate-types.nix { inherit lib; }) generateType;

  opsTypes = import ../ops/types.nix { inherit lib; };
  opsCommandType = opsTypes.opsCommandType { inherit (opsTypes) optionType argType; };

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
{
  floeOptions =
    {
      name,
      version ? null,
      drift ? [ ],
    }:
    { lab, ... }:
    let
      labImages = lab.images or { };
    in
    {
      options.floes.${name} = {
        enable = mkEnableOption "the ${name} floe";

        bundles = mkOption {
          type = types.attrsOf (k8sLib.bundleTypeOwnedBy name);
          default = { };
          description = ''
            Installable bundles this floe declares, lifted into the cluster's
            `bundles` with the key it was given here.

            Declared under the floe rather than straight into `bundles` so that
            which floe owns one is structural: ownership is the path it was
            written at, not a stamp applied afterwards. Nothing has to walk the
            module system's own `mkIf` and `mkMerge` nodes to work it out, and
            a floe written by hand is owned exactly as one built from a helper.
          '';
        };

        infra.resources = mkOption {
          type = types.attrsOf infraTypes.resourceType;
          default = { };
          description = ''
            Infrastructure this floe needs provisioned, lifted into the
            lab's stacks under the key it was given here.

            The other camp from `bundles`. A bundle is a Kubernetes resource
            a controller reconciles forever; this is a resource a plan/apply
            tool creates once and records in state. A floe says what it
            needs; the lab says which stack's state records it and which
            credentials reach it.
          '';
        };

        steps = mkOption {
          type = types.attrsOf clusterStepType;
          default = { };
          description = ''
            Plan steps this floe contributes, lifted into the cluster's
            `steps` under the key it was given here.

            Declared under the floe so that which floe a step came from is
            structural, the same reason `bundles` is. A step's `origin` is
            filled in from this path, so an anchor or cycle error names the
            floe rather than only the cluster.

            The key is not a name in the dependency namespace. A sibling is
            reached through a `provides:` token, because the fold that lifts a
            cluster's steps rekeys them to `<cluster>-<name>` before anything
            resolves anchors.
          '';
        };

        ops = mkOption {
          type = types.attrsOf (types.attrsOf opsCommandType);
          default = { };
          description = ''
            Operational commands this floe publishes, keyed by category then
            by name to match the `<lab>-ops <category> <name>` invocation.

            Lifted into the cluster's `ops`, where the same category and name
            from several clusters are merged into one command with a
            `--cluster` flag. Two enabled floes publishing the same pair on
            one cluster is refused naming both.
          '';
        };

        secrets.generate = mkOption {
          type = types.attrsOf generateType;
          default = { };
          description = ''
            Secrets this floe mints for itself, with no value authored
            anywhere, lifted into the cluster's `secrets.generate`.

            A value that exists before the lab does belongs in
            `lab.secrets.managed`, and one another cluster mints belongs in
            `secrets.subscribe`. Neither is the floe's to declare, which is
            why only `generate` is here.
          '';
        };

        verify = mkOption {
          type = types.attrsOf (import ../verify-types.nix { inherit lib; }).checkType;
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
          type = types.attrsOf (import ../lint-types.nix { inherit lib; }).checkType;
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
          type = (import ../network-policy-types.nix { inherit lib; }).networkType;
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

        drift.expected = mkOption {
          type = types.listOf driftEntryType;
          default = drift;
          description = ''
            Drift this floe expects on its own resources.

            Writable; an operator who hits a manager name the floe author
            did not anticipate can append here without forking the floe, the
            same escape-hatch reasoning as `overrides`. Aggregated into
            `cluster.drift.declarations.<floe>` when the floe is enabled.
          '';
        };

        capabilities = mkOption {
          type = (import ../../../lib/contracts/capability.nix { inherit lib; }).capabilitiesType;
          default = { };
          description = ''
            What job this floe does, so the cluster can recognise another
            floe doing the same one.

            A floe says what it is, so two floes saying they are the same
            thing is something the cluster can refuse. What a floe *needs* is
            said by its bundles, as a name in the one dependency namespace,
            and never as the name of another floe.
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
      };
    };
}
