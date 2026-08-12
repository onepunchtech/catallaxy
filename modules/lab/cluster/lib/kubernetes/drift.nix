{ lib }:

let
  inherit (lib) mkOption types;
in
{
  driftEntryType = types.submodule {
    options = {
      reason = mkOption {
        type = types.str;
        description = ''
          Why this drift is expected. REQUIRED; there is deliberately
          no default.

          A rule with no rationale is indistinguishable from a rule
          somebody added to make a red light go green, and it will be
          impossible to retire safely later. Say what writes the field
          and why the CD tool should not fight it.
        '';
        example = "velero's controller defaults spec.skipImmediately on every Schedule";
      };

      group = mkOption {
        type = types.str;
        default = "";
        description = ''
          API group of the affected kinds. Empty string for the core
          group (v1). Cluster-scope declarations of core-group kinds are
          rejected: see the assertion in
          `modules/lab/cluster/drift.nix`, because argocd's global
          `resource.customizations` key format has no unambiguous
          encoding for them. Declare those on the bundle instead.
        '';
        example = "velero.io";
      };

      kinds = mkOption {
        type = types.listOf types.str;
        description = ''
          Kinds this entry applies to. A list rather than a single kind
          so one declaration can cover an operator's whole CR family,
          netbird's Group and SetupKey share a manager and are one
          entry, not two.
        '';
        example = [
          "Group"
          "SetupKey"
        ];
      };

      managedBy = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          SSA field managers, other than the CD tool, that legitimately
          write to these kinds. The preferred way to declare drift: see
          the "managedBy vs fields" note at the top of this file.

          Find the name on a live object:
            kubectl get <kind> -A -o json --show-managed-fields \
              | jq -r '.items[].metadata.managedFields[].manager'

          A name that matches nothing is a silent no-op: the rule never
          fires and the resource stays drifted. Nothing in Nix can
          validate a string that only exists in a running cluster, so
          check it against a real object rather than guessing from the
          operator's Deployment name; they frequently differ (kaniop
          registers per-CRD names like `kanidmoauth2clients.kaniop.rs`,
          and some controllers register as literally `unknown`).
        '';
        example = [ "velero-server" ];
      };

      fields = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Escape hatch for fields no manager cleanly owns. Prefer
          `managedBy`; read the hazard note at the top of this file
          before using this.

          Author-facing dotted paths, NOT RFC 6901: the lowering does
          the `~0`/`~1` escaping. Quote a segment containing dots or
          slashes:

            spec.skipImmediately
            metadata.annotations."reloader.stakater.com/last-reloaded-from"

          Writing `~1` by hand means the CD tool's encoding has leaked
          into a floe, which is exactly what this option exists to
          prevent.
        '';
        example = [ "spec.skipImmediately" ];
      };

      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Restrict to a single named resource. Bundle-scope only,
          argocd's global `resource.customizations` has no name
          selector, so a cluster-scope entry setting this is rejected
          at eval time.
        '';
      };

      namespace = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Restrict to one namespace. Bundle-scope only, same reason as `name`.";
      };

      shareable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether these `managedBy` names apply to EVERY declared kind
          cluster-wide, not just this entry's `kinds`.

          Defaults false, and you almost certainly want that. An
          operator writes only to its own CRs, so kind-scoping already
          covers it; making operator names cross-kind produces
          `velero-server` on `HTTPRoute` and kaniop's per-CRD names on
          `apps/Deployment`: noise that also silently suppresses
          reconciliation if such a manager ever does touch the kind.

          The framework's own bootstrap actors are cross-kind by nature
          and come from `cluster.drift.builtinManagers`; a floe author
          never needs to name them. Set this true only for a manager
          that genuinely writes across unrelated kinds.
        '';
      };
    };
  };
}
