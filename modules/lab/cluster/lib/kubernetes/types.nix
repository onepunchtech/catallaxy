{
  lib,
  k8sVersion ? "1.31",
}:

let
  inherit (lib) mkOption types;

  generatedTypes = import ./generated/index.nix { inherit lib; };

  versionedTypes = generatedTypes.forVersion k8sVersion;

  typesByKind = generatedTypes.typesByKind versionedTypes;

  coreKinds = generatedTypes.coreKinds versionedTypes;

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
  # pair outside the committed schemas keeps the untyped spec it had before.
  #
  # Resolution is on the (apiVersion, kind) pair because `kind` alone does not
  # identify a schema. `Cluster` is CloudNativePG's, Cluster API's and
  # Crossplane's; `Backup` is velero's and CloudNativePG's; `Event` and
  # `HorizontalPodAutoscaler` each exist twice in core Kubernetes.
  specTypeFor =
    apiVersion: kind:
    let
      resolved = generatedTypes.resolveResourceType typesByKind apiVersion kind;
    in
    if resolved == null then types.nullOr types.attrs else (resolved.getSubOptions [ ]).spec.type;

  probeRequires = {
    condition = [
      "resource"
      "condition"
    ];
    jsonpath = [
      "resource"
      "jsonpath"
    ];
    exists = [ "resource" ];
    http = [ "url" ];
    tcp = [
      "host"
      "port"
    ];
    dns = [ "hostname" ];
    script = [ "script" ];
    kubectl-wait = [ ];
  };

  readyProbeType =
    let
      str = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    in
    types.submodule {
      options = {
        kind = mkOption {
          type = types.enum (lib.attrNames probeRequires);
          description = ''
            Which probe shape this is. Every kind but `kubectl-wait` is
            rendered by `lib/util/wait.nix`, which refuses a probe missing a
            field its kind needs; `kubectl-wait` passes `args` through.
          '';
        };

        resource = str // {
          description = "`kind/name` to wait on, for the kinds that ask kubectl.";
        };
        namespace = str // {
          description = "Namespace holding `resource`. Cluster-scoped kinds leave it null.";
        };
        condition = str // {
          description = ''
            Condition that must be True, for `kind = "condition"`.

            Only Deployments carry `Available` and only Jobs carry `complete`.
            A StatefulSet or DaemonSet waited on for a condition it does not
            have blocks until the timeout however healthy it is.
          '';
        };
        jsonpath = str // {
          description = ''JSONPath expression, for `kind = "jsonpath"`.'';
        };
        value = mkOption {
          type = types.nullOr (types.either types.str types.int);
          default = null;
          description = "Value `jsonpath` must equal. Null waits for it to exist.";
        };
        url = str // {
          description = ''URL to fetch, for `kind = "http"`.'';
        };
        expectedStatus = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "HTTP status that counts as ready. Defaults to 200.";
        };
        caBundleMount = mkOption {
          type = types.nullOr types.attrs;
          default = null;
          description = "CA bundle to trust when fetching `url`.";
        };
        host = str // {
          description = ''Host to connect to, for `kind = "tcp"`.'';
        };
        port = mkOption {
          type = types.nullOr types.port;
          default = null;
          description = ''Port to connect to, for `kind = "tcp"`.'';
        };
        hostname = str // {
          description = ''Name that must resolve, for `kind = "dns"`.'';
        };
        script = str // {
          description = ''Shell script that exits 0 when ready, for `kind = "script"`.'';
        };
        args = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = ''Arguments passed straight to kubectl, for `kind = "kubectl-wait"`.'';
        };
        image = str // {
          description = "Image the probe runs in. Each kind has a default.";
        };
        timeout = str // {
          description = "How long to keep asking before giving up.";
        };
        interval = str // {
          description = "How long to wait between attempts, for the polling kinds.";
        };
      };
    };

  kubernetesResourceType = types.submodule (
    { name, config, ... }:
    {
      options = {
        apiVersion = mkOption {
          type = types.str;
          default = "";
          description = ''
            Kubernetes API version (e.g., 'v1', 'apps/v1'). Together with
            `kind` it picks the type `spec` is checked against, so it is read
            while the option tree is built and carries a default for that
            reason. A resource that leaves it empty is rejected by an
            assertion rather than by the type. For the same reason it has to
            be a literal: a value computed from the option tree would recurse.
          '';
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
          type = specTypeFor config.apiVersion config.kind;
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

  bundleModule =
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
            Names this bundle needs READY (applied AND their readyProbe
            passed) before it starts. Every name must be provided by another
            bundle in the same cluster; eval fails otherwise with a
            fingerprint pointing at the culprit.

            `step:<token>` reaches out of the cluster to the lab's plan
            instead, for something that has to be true before any manifest is
            applied. It adds no wave ordering, because every bundle here is
            applied by one step: the lab checks that whatever publishes the
            token runs before that step, and refuses if it does not.
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

        conflicts = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Names this bundle refuses to share a cluster with, in the same
            namespace `provides` and `requires` use.

            A name only one implementation of can be correct is stated by
            providing it and conflicting with it at the same time, the way an
            MTA both provides and conflicts with `mail-transport-agent`. A
            bundle never conflicts with itself, so one provider is fine and
            two is an evaluation error naming both.

            Two Gateway API implementations are the motivating case: they claim
            the same listeners and the same routes, and which one wins depends
            on reconcile order, so the cluster comes up and then disagrees with
            itself.
          '';
        };

        disableWith = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "floes.cilium.gatewayAPI.enable = false";
          description = ''
            The setting that stops this bundle providing what it provides,
            written as a lab author would write it.

            Only read when a `conflicts` refusal names this bundle. A refusal
            that does not say what to change makes the reader go and find out
            which of two providers is the one they can turn off, and for a
            provider of several names the answer is rarely `enable = false`.
          '';
        };

        declaredBy = mkOption {
          internal = true;
          type = types.str;
          description = ''
            Which floe declared this bundle, or null when the cluster itself
            did, for `floe:<name>` anchors.

            Required, and nullable, because those are different answers and
            only one of them can be assumed. Three things read this and skip a
            bundle that answers nothing: the allow rules in
            `cluster.security.networkPolicies`, `imageCompleteness`, and the
            SBOM. When it defaulted to null a bundle whose floe went unnamed
            fell out of all three and nothing said so.

            the key it is declared under sets it. A module that declares a bundle by hand says it
            itself, and is refused until it does.
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

          # Every kind gets every field so the shape is checked, and a
          # condition probe has no business carrying a null `hostname` into a
          # rendered tree. Dropping them here means nothing downstream, in
          # Nix or in the CLI, has to know they were ever there.
          apply = p: if p == null then null else lib.filterAttrs (_: v: v != null) p;
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
    };

  bundleType = types.submodule bundleModule;

  # A bundle declared under `floes.<name>.bundles` is that floe's by
  # construction, so it answers `declaredBy` without anyone stamping it
  # afterwards. `mkDefault`, so two floes declaring the same bundle key still
  # collide on who owns it rather than one silently winning.
  bundleTypeOwnedBy =
    owner:
    types.submodule [
      bundleModule
      { declaredBy = lib.mkDefault owner; }
    ];

in
{
  inherit
    kustomizeType
    helmChartType
    kubernetesResourceType
    bundleType
    bundleTypeOwnedBy
    ;

  inherit generatedTypes coreKinds;

  inherit typesByKind;

  k8sTypes = versionedTypes;

  forK8sVersion = generatedTypes.forVersion;
}
