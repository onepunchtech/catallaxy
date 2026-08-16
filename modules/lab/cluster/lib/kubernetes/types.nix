{
  lib,
  k8sVersion ? "1.31",
}:

let
  inherit (lib) mkOption types;

  generatedTypes = import ./generated/index.nix { inherit lib; };

  versionedTypes = generatedTypes.forVersion k8sVersion;

  allResourceTypes = generatedTypes.flattenTypes versionedTypes;

  metadataType = import ./generated/k8s-api.nix;

  kustomizeType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable kustomize-based patching of helm output";
      };

      patches = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          Strategic merge patches to apply to helm output.
          Each patch is an attribute set that will be merged with matching resources.
        '';
      };

      patchesJson6902 = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          JSON Patch (RFC 6902) operations to apply to helm output.
        '';
      };

      resources = mkOption {
        type = types.listOf (types.either types.path types.str);
        default = [ ];
        description = ''
          Additional resources to include alongside helm output.
          Can be paths to YAML files or inline YAML strings.
        '';
      };
    };
  };

  helmChartType = types.submodule (
    { name, ... }:
    {
      options = {
        chart = mkOption {
          type = types.package;
          description = "Helm chart derivation";
        };

        releaseName = mkOption {
          type = types.str;
          default = name;
          description = "Helm release name (defaults to attribute name)";
        };

        namespace = mkOption {
          type = types.str;
          default = "default";
          description = "Kubernetes namespace for the release";
        };

        values = mkOption {
          type = types.attrs;
          default = { };
          description = "Helm values to pass to the chart";
        };

        kustomize = mkOption {
          type = kustomizeType;
          default = { };
          description = "Kustomize patching configuration";
        };

        extraOpts = mkOption {
          type = types.listOf types.str;
          default = [ "--skip-tests" ];
          description = "Extra options to pass to helm template";
        };

        createNamespace = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to create the namespace if it doesn't exist";
        };
      };
    }
  );

  # The generated resource types carry `freeformType = types.attrs`, so this
  # checks the fields Kubernetes knows about and lets unknown ones through. A
  # kind outside the committed schemas keeps the untyped spec it had before.
  specTypeFor =
    kind:
    let
      kindType = allResourceTypes.${kind} or null;
      subOptions = if kindType == null then { } else kindType.getSubOptions [ ];
    in
    subOptions.spec.type or (types.nullOr types.attrs);

  readyProbeType = types.submodule {
    options.kind = mkOption {
      type = types.enum [
        "condition"
        "jsonpath"
        "exists"
        "http"
        "tcp"
        "dns"
        "script"
        "kubectl-wait"
      ];
      description = ''
        Which probe shape this is. Every kind but `kubectl-wait` is
        rendered by `lib/util/wait.nix`; `kubectl-wait` passes `args`
        through to kubectl.
      '';
    };
    freeformType = types.attrs;
  };

  kubernetesResourceType = types.submodule (
    { name, config, ... }:
    {
      options = {
        apiVersion = mkOption {
          type = types.str;
          description = "Kubernetes API version (e.g., 'v1', 'apps/v1')";
        };

        kind = mkOption {
          type = types.str;
          default = "";
          description = ''
            Kubernetes resource kind (e.g., 'Service', 'Deployment'). It
            picks the type `spec` is checked against, so it is read while
            the option tree is built and carries a default for that reason.
            A resource that leaves it empty is rejected by an assertion
            rather than by the type.
          '';
        };

        metadata = mkOption {
          type = types.submodule metadataType;
          default = {
            name = name;
          };
          description = "Resource metadata";
        };

        spec = mkOption {
          type = specTypeFor config.kind;
          default = null;
          description = ''
            Resource spec. When the kind is one of the generated Kubernetes
            ${k8sVersion} API or CRD types, every field Kubernetes declares
            is checked against its type, so `replicas = "three"` fails
            evaluation naming the option path.

            Two things it does not catch. The generated types default every
            field to null, so leaving out a field Kubernetes requires is not
            an error here. And they carry a freeform escape hatch, so a
            misspelled key passes through to the manifest.
          '';
        };

        data = mkOption {
          type = types.nullOr (types.attrsOf types.str);
          default = null;
          description = "Data for ConfigMap/Secret resources";
        };

        stringData = mkOption {
          type = types.nullOr (types.attrsOf types.str);
          default = null;
          description = "String data for Secret resources";
        };
      };

      freeformType = types.attrs;
    }
  );

  bundleType = types.submodule (
    { name, ... }:
    {
      options = {
        resources = mkOption {
          type = types.attrsOf kubernetesResourceType;
          default = { };
          description = ''
            Typed Kubernetes resources to include in this phase.
            A resource whose `kind` is one of the generated K8s ${k8sVersion}
            API or CRD types has its `spec` checked against that type, so a
            field given the wrong type fails evaluation. Kinds outside those
            schemas, and fields Kubernetes does not declare, are passed
            through unchecked.
          '';
        };

        yamls = mkOption {
          type = types.listOf (types.either types.str types.path);
          default = [ ];
          description = ''
            Raw YAML manifests to include in this phase.
            Use this as an escape hatch when typed resources don't fit.
            Can be inline strings or paths to YAML files.
          '';
        };

        helmCharts = mkOption {
          type = types.attrsOf helmChartType;
          default = { };
          description = ''
            Helm charts to render for this phase.
            Charts are rendered at build time using helm template,
            with optional kustomize patching.
          '';
        };

        createNamespaces = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Namespaces to create for this phase";
        };

        includeInBootstrap = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether this bundle is emitted in the bootstrap-restricted
            manifest set (`stage1/`). For a self-provisioning cluster
            (k3d bootstrap → pivoted cloud), bootstrap-only manifests
            are the DAG closure of `cluster.provisioning.rootBundles`;
            everything outside that closure is deferred to the
            post-pivot full deploy. Setting `includeInBootstrap = false`
            on an
            individual bundle excludes it from stage1 while keeping
            it in the full manifest set.

            Use this for operators whose only reason to be on the
            bootstrap is that they share a phase with Crossplane
            (external-dns, kaniop, cnpg, ...); they don't do useful
            work on the ephemeral k3d and may actively harm state
            (e.g. external-dns fighting with its post-pivot twin
            over Cloudflare records under the same TXTOwnerID).
          '';
        };

        after = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Bundles this one applies AFTER: ordering only. Use
            `requires` when the successor needs the predecessor to be
            READY, not merely applied.

            Empty by default. Framework auto-edges (namespace → workload,
            CRD → CR, SecretStore → ExternalSecret) supplement this at
            eval time; users only author non-structural ordering.
          '';
        };

        requires = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            `provides`-tokens this bundle needs READY (applied AND its
            readyProbe has passed) before it starts. Every token must
            be provided by another bundle in the same cluster; eval
            fails otherwise with a fingerprint pointing at the culprit.
          '';
        };

        provides = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Tokens this bundle emits when it becomes READY. Other
            bundles gate on them via `requires`. Free-form strings,
            convention is `<scope>/<subject>/<state>`
            (e.g. `cert-manager/default-issuer/ready`,
            `netbird/operator/ready`, `stage1` for the bootstrap-set
            marker).

            The framework auto-populates structural tokens
            (`namespace/<n>/exists`, `crd/<group>/<kind>/established`,
            `bundle/<name>/ready`) on top of what you declare; you
            never need to write those by hand.
          '';
        };

        floe = mkOption {
          internal = true;
          type = types.nullOr types.str;
          default = null;
          description = ''
            Which floe declared this bundle, for `floe:<name>` anchors.
            Stamped by `mkFloe`; a bundle a lab declares directly has none.
          '';
        };

        awaitRollout = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether the deploy step waits for this bundle's workloads to
            reach `Available` before moving on.

            Set `false` when a workload gates at runtime on something it
            does not mint, nothing in the deploy can make that thing
            appear, and its own initContainer is the real gate.

            The netbird agent on a peer cluster used to be the motivating
            case: its setup key arrived by a plan step that necessarily
            ran after the deploy, so waiting for the Deployment to go
            Available deadlocked the plan against itself (2026-07-31).
            That is no longer true. The key is authored in the lab's
            secret store and projected during the deploy, so the bundle
            waits on the Secret with a `readyProbe` and awaits its
            rollout like anything else. Prefer that shape: if the value
            can be made to arrive during the deploy, wait for it rather
            than opting out of waiting.

            This is a statement a bundle makes about ITSELF. It names no
            step, cluster or peer, so it survives the plan being
            reordered.

            Only applies to typed `resources`. Workloads coming from
            `helmCharts` are always waited on: the annotation is stamped
            during resource rendering, and helm output is passed through
            as-is.
          '';
        };

        readyProbe = mkOption {

          type = types.nullOr readyProbeType;
          default = null;
          description = ''
            How to determine this bundle is READY beyond "kubectl apply
            returned 0". Uses the probe DSL from `lib/util/wait.nix`,
            any tagged shape it accepts (`condition`, `jsonpath`,
            `exists`, `http`, `tcp`, `dns`, `script`), plus a
            `kubectl-wait` escape hatch taking free-form `args`.

            `kind` is checked at evaluation, so a misspelled one is an
            error here rather than a probe that never fires and a wait
            that times out minutes later with nothing pointing at the
            cause. The fields each kind reads are not yet typed.

            `condition` / `jsonpath` / `exists` / `kubectl-wait` /
            `script` run host-side against the operator's kubeconfig.
            `http` / `tcp` / `dns` address in-cluster endpoints the host
            can't reach, so the renderer turns them into a one-shot Pod
            running the same container `wait.nix` builds for
            initContainers. That Pod carries no ServiceAccount, so those
            shapes can't use `caBundleMount`: for a probe needing the
            lab CA, put a `mkWaitInitContainer` in the bundle's own
            workload, where the volume exists, and give the bundle a
            kubectl-native readyProbe.

            When `null`, the bundle is considered ready as soon as its
            resources are applied. Use `null` for bundles whose
            resources are purely declarative (Secret, ConfigMap,
            Namespace); use a probe for bundles that mint state
            (Certificate, CRD, OAuth2 client, external DB) so
            downstream `requires` gates block until the state is real.

            Example:
              readyProbe = {
                kind = "condition";
                resource = "certificate/lab-ca";
                namespace = "cert-manager";
                condition = "Ready";
                timeout = "3m";
              };
          '';
        };

        owner = mkOption {
          type = types.submodule {
            options = {
              bootstrap = mkOption {
                type = types.nullOr (
                  types.enum [
                    "install-target"
                    "argocd"
                  ]
                );
                default = null;
                description = ''
                  Role this bundle plays during the first deploy pass.
                  `"install-target"`: part of the pre-gitops install
                  target: applied by whichever imperative actor
                  `lab.cd.bootstrap` selects (kapp / kubectl-ssa /
                  helm) before argocd can reconcile from git. Any
                  bundle argocd itself transitively depends on
                  (argocd server, its git repo host, cert-manager,
                  gateway, external-secrets, ...) MUST be
                  `"install-target"`. `"argocd"`: the bundle is
                  emitted into the argocd git tree only; the
                  imperative actor never touches it. `null`: inherit
                  from `lab.cd.defaultOwner.bootstrap`.

                  Semantic name (role), not a tool name. The floe
                  author doesn't need to know which imperative tool
                  the lab is configured to use.
                '';
              };
              steady = mkOption {
                type = types.nullOr (
                  types.enum [
                    "imperative"
                    "argocd"
                  ]
                );
                default = null;
                description = ''
                  Who owns this bundle at steady state, after any
                  bootstrap handoff. `"imperative"`: the imperative
                  actor (kapp under `cd.strategy = "kapp"`, or
                  whichever `cd.bootstrap` tool applies the
                  install-target set) remains the owner; every
                  `lab up` re-applies the bundle, argocd never sees
                  it. `"argocd"`; argocd takes over after the initial
                  apply; the bundle is rendered into the git tree
                  and argocd reconciles from there.

                  When `bootstrap = "install-target"` and
                  `steady = "argocd"`, the imperative actor applies
                  once at bootstrap and argocd inherits ownership via
                  Server-Side Apply field-manager migration on its
                  first sync. This is the "install-target → gitops"
                  pattern used by argocd, forgejo, cert-manager, and
                  every other CD-controller dependency.

                  `null` inherits from `lab.cd.defaultOwner.steady`.
                  Only `bootstrap = "install-target"; steady = "argocd"`
                  is a valid asymmetric configuration; the reverse is
                  rejected by an eval-time assertion.
                '';
              };
            };
          };

          default = {
            bootstrap = null;
            steady = null;
          };
          description = "Who owns this bundle's resources at each stage: which tool applies it during bootstrap, and which reconciles it afterwards.";
        };
      };
    }
  );

in
{
  inherit
    kustomizeType
    helmChartType
    kubernetesResourceType
    bundleType
    ;

  inherit generatedTypes;

  inherit allResourceTypes;

  k8sTypes = versionedTypes;

  forK8sVersion = generatedTypes.forVersion;
}
