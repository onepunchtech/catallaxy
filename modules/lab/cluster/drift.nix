{ config, lib, ... }:

let
  inherit (lib) mkOption types;
  inherit (import ./lib/kubernetes/drift.nix { inherit lib; }) driftEntryType;

  cfg = config.cluster.drift;

  floeEntries = lib.concatMap (
    floeName:
    let
      floe = config.floes.${floeName};
    in
    if (floe.enable or false) then (floe.drift.expected or [ ]) else [ ]
  ) (lib.attrNames (config.floes or { }));

  allEntries = floeEntries ++ lib.concatLists (lib.attrValues cfg.declarations);

  sharedManagers = lib.concatMap (
    e:
    if e.shareable then
      lib.filter (m: !(builtins.elem m cfg.nonAggregatedManagers)) e.managedBy
    else
      [ ]
  ) allEntries;

  cdManagers = [
    "argocd-controller"
    "argocd-application-controller"
  ];

  offendingCdEntries = lib.filter (e: lib.any (m: builtins.elem m cdManagers) e.managedBy) allEntries;
  emptyReasonEntries = lib.filter (e: lib.trim e.reason == "") allEntries;
  emptyKindsEntries = lib.filter (e: e.kinds == [ ]) allEntries;
  scopedEntries = lib.filter (e: e.name != null || e.namespace != null) allEntries;
  coreGroupEntries = lib.filter (e: e.group == "") allEntries;
  badManagerNames = lib.concatMap (
    e: lib.filter (m: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" m == null) e.managedBy
  ) allEntries;

in
{
  options.cluster.drift = {
    declarations = mkOption {
      type = types.attrsOf (types.listOf driftEntryType);
      default = { };
      description = ''
        Lab-level drift declarations, keyed by an arbitrary label.

        Floes do NOT write here: their declarations are read straight
        off `floes.<n>.drift.expected` (see the note above `floeEntries`;
        a write-based aggregate deadlocks eval). This option is the
        escape hatch for a lab hitting drift no upstream floe covers,
        and for framework-owned rules that belong to no single floe.
      '';
    };

    builtinManagers = mkOption {
      type = types.listOf types.str;
      default = [
        "kapp"
        "catallaxy-bootstrap"
        "helm"
      ];
      description = ''
        The framework's own imperative-actor identities; whichever of
        these `lab.cd.bootstrap` selects will have applied resources
        before argocd took over. Listed unconditionally: a manager a
        given lab never uses simply matches nothing.
      '';
    };

    nonAggregatedManagers = mkOption {
      type = types.listOf types.str;
      default = [ "unknown" ];
      description = ''
        Manager names that must never join the cluster-wide aggregate,
        even when a floe declares them shareable.

        `unknown` is denied because it is not a name; several
        controllers register as literally that, so unioning it onto
        every declared kind would silently ignore fields written by any
        of them. A floe needing it still gets it on its OWN kinds; only
        the cross-floe union is blocked.
      '';
    };

    out = {
      aggregateManagers = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        description = ''
          Union of `builtinManagers` and every shareable manager any
          enabled floe declared. Applied to every declared (group,kind)
          never to argocd's `.all`, which would strip atomic fields a
          foreign manager co-owns and create permanent OutOfSync.
        '';
      };

      entries = mkOption {
        type = types.listOf types.raw;
        readOnly = true;
        description = "Flattened cluster-scope declarations, ready for lowering.";
      };
    };
  };

  config = {

    cluster.drift.declarations._framework = [
      {
        group = "apps";
        kinds = [
          "Deployment"
          "StatefulSet"
          "DaemonSet"
        ];

        reason = ''
          Workloads are created by the imperative bootstrap actor before
          argocd takes over; server-defaulted and immutable-at-create
          spec fields stay owned by it.
        '';
      }
      {
        group = "apiextensions.k8s.io";
        kinds = [ "CustomResourceDefinition" ];
        fields = [
          "spec.conversion.webhook.clientConfig.service"
          "spec.conversion.webhook.clientConfig.caBundle"
        ];
        reason = ''
          Operator-published CRDs ship a placeholder conversion-webhook
          clientConfig that the operator's cert-controller patches at
          runtime (external-secrets and cert-manager both do this). A
          field rule rather than a manager rule because the patching
          identity varies by operator.
        '';
      }
    ];

    cluster.drift.out = {
      aggregateManagers = lib.sort (a: b: a < b) (lib.unique (cfg.builtinManagers ++ sharedManagers));

      entries = lib.filter (e: e.name == null && e.namespace == null) allEntries;
    };

    assertions = [
      {
        assertion = offendingCdEntries == [ ];
        message = ''
          cluster.drift: a declaration lists argocd's own field manager in `managedBy`
          (${lib.concatMapStringsSep ", " (e: lib.concatStringsSep "/" e.kinds) offendingCdEntries}).

          That tells argocd to ignore every field it manages. The
          Application then reports Synced forever and silently stops
          reconciling: strictly worse than the drift being worked
          around, because nothing surfaces it. Name the FOREIGN
          controller that writes the field instead.
        '';
      }
      {
        assertion = emptyReasonEntries == [ ];
        message = ''
          cluster.drift: a declaration has an empty `reason`. State what writes
          the field and why the CD tool should not fight it: a rule
          nobody can justify later is a rule nobody can safely delete.
        '';
      }
      {
        assertion = emptyKindsEntries == [ ];
        message = "cluster.drift: a declaration has an empty `kinds` list; it would match nothing.";
      }
      {
        assertion = badManagerNames == [ ];
        message = ''
          cluster.drift: invalid manager name(s): ${
            lib.concatStringsSep ", " (map (m: "'${m}'") badManagerNames)
          }.
          Expected a bare field-manager identifier. A multi-line string here
          usually means a YAML list was pasted in verbatim.
        '';
      }
      {
        assertion = scopedEntries == [ ];
        message = ''
          cluster.drift: a floe-scope declaration sets `name`/`namespace`, which
          argocd's global `resource.customizations` cannot express.
          Declare it on the bundle instead (`bundleType.drift.expected`),
          which renders into that Application's own ignoreDifferences.
        '';
      }
      {
        assertion = coreGroupEntries == [ ];
        message = ''
          cluster.drift: a floe-scope declaration uses the core API group
          (`group = ""`). argocd's `resource.customizations.<group>_<Kind>`
          key has no unambiguous encoding for it. Declare on the bundle
          instead, where the group is a plain field.
        '';
      }
    ];
  };
}
