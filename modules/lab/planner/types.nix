{ lib }:

let
  inherit (lib) mkOption types;

  kinds = import ./kinds { inherit lib; };

  defaultDirection =
    kind:
    let
      directions = if kind == null then [ ] else kinds.${kind}.directions;
    in
    if lib.length directions == 1 then
      lib.head directions
    else if kind == null then
      "deploy"
    else
      throw ''
        A step of kind '${kind}' must set `direction`, because the kind runs
        in more than one: ${lib.concatStringsSep ", " directions}.
      '';

  policyOptions = {
    onFailure = mkOption {
      type = types.enum [
        "fatal"
        "continue"
      ];
      default = "fatal";
      description = ''
        What a non-zero exit means. `fatal` aborts the plan, which is right
        for a precondition. `continue` records the failure and carries on:
        what cleanup work wants, since one cluster's failed teardown should
        not strand the rest of the lab.
      '';
    };

    interactive = mkOption {
      type = types.bool;
      default = false;
      description = ''
        The step cannot complete without a human, so the CLI runs it once
        instead of applying the retry policy its kind's idempotency class
        implies.

        The two are orthogonal. Re-running netbird's mesh join is safe, which
        makes it idempotent, but an automatic retry issues a fresh browser
        login URL and invalidates the one the operator is part-way through
        completing, so the retry defeats the step it is retrying (mesh.local,
        2026-08-04).
      '';
    };

    skipIfClusterReachable = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Cluster name whose kube reachability short-circuits this step. Used
        by post-pivot and re-run flows that are no-ops once the cloud-side
        target is up.
      '';
    };
  };

  declaredPolicyType = types.submodule { options = policyOptions; };

  plannedPolicyType = types.submodule {
    options = policyOptions // {
      retry = mkOption {
        internal = true;
        type = types.enum [
          "idempotent"
          "oneShot"
          "destructive"
        ];
        description = "The kind's idempotency class, which drives the executor's retry policy.";
      };
    };
  };

  stepModule =
    { scoped }:
    (
      { name, config, ... }:
      {
        options = {

          name = mkOption {
            type = types.str;
            default = name;
            description = "Step name (defaults to attr key). Must be globally unique.";
          };

          kind = mkOption {
            type = types.nullOr (types.enum (lib.attrNames kinds));
            default = null;
            description = ''
              Step kind, one of the entries in
              `modules/lab/planner/kinds/`. It selects the type of `params`,
              the directions this step may run in, and the executor's retry
              policy.
            '';
          };

          direction = mkOption {
            type = types.enum [
              "deploy"
              "teardown"
              "both"
            ];
            default = defaultDirection config.kind;
            defaultText = lib.literalMD "the kind's direction, when it has exactly one";
            description = ''
              Which plan direction this step belongs to. A kind that runs in
              exactly one direction supplies the default; `run-script` and
              `destroy-cluster` run in both, so they must say.
            '';
          };

          after = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = lib.literalExpression ''[ (t.needs (t.cluster "mgmt").reachable) ]'';
            description = ''
              Names this step runs after, in the one dependency namespace.

              A bare name is a token some step publishes; `provides:<token>`
              says the same thing explicitly. `kind:<kind>` and
              `kind:<kind>:<cluster>` address steps by what they are. Any of
              them behind `optional:` is allowed to match nothing.

              A step's own key is not a name here. It belongs to whichever
              module emitted it, and a cluster's steps are renamed to
              `<cluster>-<name>` before the sort runs, so the key you wrote
              no longer exists by then. This is the one place the grammar
              differs from a bundle's, where a bundle name is stable and does
              resolve.

              Build them with `lib.planTokens` rather than writing the
              strings, so a typo fails eval here instead of quietly
              producing no edge.
            '';
          };
          before = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              Anchors naming steps this one runs before, in the same grammar
              as `after`. Reach for it when the steps you have to precede are
              not yours to change; when they are, having them wait on a token
              you publish says the same thing in one place.
            '';
          };
          requires = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              Names that must be true before this step runs, in the same
              grammar as `after`.

              The two differ in strength rather than in what a name means: a
              name nobody supplies fails eval here, where `after` would take
              `optional:` and produce no edge.
            '';
          };
          conflicts = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              Names a second publisher of would be a race rather than a
              merge.

              A step that publishes an exclusive name also conflicts with it,
              so two publishers collide and one does not collide with itself.
              Checked per direction: a deploy step and a teardown step never
              run together, so they cannot conflict.
            '';
          };
          provides = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = lib.literalExpression "[ t.lab.reachable ]";
            description = ''
              Tokens this step makes true. A token names a state rather than
              a step, so splitting or renaming the step that publishes it
              breaks nothing downstream.
            '';
          };

          policy = mkOption {
            type = declaredPolicyType;
            default = { };
            description = ''
              How the executor treats this step, independently of its kind:
              what a failure means, whether a human is in the loop, and
              whether a reachable cluster makes it a no-op.
            '';
          };

          params = mkOption {
            type =
              if config.kind == null then types.submodule { } else types.submodule kinds.${config.kind}.params;
            default = { };
            description = ''
              Kind-specific payload, typed by the entry for `kind` in
              `modules/lab/planner/kinds/`. What each kind accepts is in
              [Plan Step Kinds](../step-kinds.md).
            '';
          };

          description = mkOption {
            type = types.str;
            default = "";
            description = "One line shown in `cata lab plan` and in the executor's progress output.";
          };

          cluster = mkOption {
            internal = true;
            type = types.nullOr types.str;
            default = null;
            description = ''
              Cluster this step acts on, filled in by the fold that lifts a
              cluster's steps into `lab.steps`. It is what `kind:<k>:<cluster>`
              anchors match, and what a kind's `kubeContext` param defaults
              from.
            '';
          };

          origin = mkOption {
            internal = true;
            type = types.nullOr types.str;
            default = null;
            description = ''
              Where this step was written, for error messages. The cluster
              fold rekeys `clusters.<c>.steps.<n>` to `<c>-<n>`, a name the
              author never typed, so anchor and cycle errors quote this
              instead.
            '';
          };
        }
        // lib.optionalAttrs scoped {
          scope = mkOption {
            type = types.enum [
              "lab"
              "cluster"
            ];
            default = "cluster";
            description = ''
              Whether this step acts on the cluster that declares it, or on
              the lab as a whole. A lab-scope step declared by a cluster runs
              once no matter how many clusters declare it, which is what a
              host-side hook wants.
            '';
          };
        };
      }
    );
in
{
  declaredStepType = types.submodule (stepModule {
    scoped = false;
  });
  clusterStepType = types.submodule (stepModule {
    scoped = true;
  });

  plannedStepType = types.submodule {
    options = {
      name = mkOption {
        internal = true;
        type = types.str;
      };
      origin = mkOption {
        internal = true;
        type = types.str;
      };
      kind = mkOption {
        internal = true;
        type = types.str;
      };
      description = mkOption {
        internal = true;
        type = types.str;
        default = "";
      };
      cluster = mkOption {
        internal = true;
        type = types.nullOr types.str;
        default = null;
      };
      policy = mkOption {
        internal = true;
        type = plannedPolicyType;
      };
      params = mkOption {
        internal = true;
        type = types.attrs;
        default = { };
      };
    };
  };
}
