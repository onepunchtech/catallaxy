{ lib }:

let
  inherit (lib) mkOption types;

  readOnlyOperations = [
    "assert"
    "error"
  ];
in
{
  inherit readOnlyOperations;

  /*
    A JMESPath key matching a resource whose `type` condition is present and
    is not `status`.

    The parentheses are load-bearing: `|` binds looser than `&&` in JMESPath,
    so writing the two halves without them parses as a pipeline and quietly
    evaluates to nonsense rather than erroring. The null guard is equally
    load-bearing: selection is a wildcard over the kind, so a resource that
    has not reported the condition yet would otherwise match and fire.
  */
  conditionIsNot =
    {
      type,
      status ? "True",
    }:
    let
      value = "(status.conditions[?type == '${type}'] | [0].status)";
    in
    "(${value} != null && ${value} != '${status}')";

  fieldIsNot = { field, value }: "(${field} != null && ${field} != '${value}')";

  checkType = types.submodule (
    { name, config, ... }:
    {
      options = {
        description = mkOption {
          type = types.str;
          description = "What this check proves about the running lab.";
        };

        timeout = mkOption {
          type = types.str;
          default = "2m";
          description = ''
            How long the assertion is re-evaluated before it is called a
            failure. The runner polls rather than sampling once, so this is
            how long a controller has to converge, not a sleep.
          '';
        };

        expect = mkOption {
          type = types.nullOr types.attrs;
          default = null;
          example = lib.literalExpression ''
            {
              apiVersion = "cert-manager.io/v1";
              kind = "Certificate";
              metadata = {
                name = "lab-ca";
                namespace = "cert-manager";
              };
              status.conditions = [
                {
                  type = "Ready";
                  status = "True";
                }
              ];
            }
          '';
          description = ''
            A partial resource that must be present and must match.
            Chainsaw's `assert`.

            **Naming a kind without a name means "at least one".** With two
            resources of that kind, one matching and one not, this passes.
            That makes it the wrong tool for "every Application is
            Healthy": use `reject` for that, which is the negation and so
            holds for all of them.
          '';
        };

        reject = mkOption {
          type = types.listOf types.attrs;
          default = [ ];
          example = lib.literalExpression ''
            [
              {
                apiVersion = "argoproj.io/v1alpha1";
                kind = "Application";
                metadata.namespace = "argocd";
                "(status.health.status != null && status.health.status != 'Healthy')" = true;
              }
            ]
          '';
          description = ''
            Partial resources that must match nothing. Chainsaw's `error`,
            and the way to say "every one of these is fine": assert that
            none of them is not fine.

            Guard the field against null. Selection is a wildcard over the
            kind, so it picks up resources you did not think about, and
            every namespace carries an auto-injected `kube-root-ca.crt`
            whose missing field makes a bare `field != 'x'` evaluate true
            and fire the rejection.
          '';
        };

        steps = mkOption {
          type = types.listOf types.attrs;
          default = [ ];
          description = ''
            Raw Chainsaw steps, for an assertion `expect` and `reject`
            cannot express.

            Operations are restricted to `assert` and `error`.
            `cata lab verify` reads a lab, it does not change one, and an
            operation that could mutate fails eval rather than being caught
            in review.
          '';
        };

        out.steps = mkOption {
          internal = true;
          readOnly = true;
          type = types.listOf types.attrs;
          description = "The check lowered to Chainsaw steps.";
        };
      };

      config.out.steps =
        if config.steps != [ ] then
          config.steps
        else
          [
            {
              inherit name;
              try =
                lib.optional (config.expect != null) {
                  "assert" = {
                    inherit (config) timeout;
                    resource = config.expect;
                  };
                }
                ++ map (resource: {
                  error = {
                    inherit (config) timeout;
                    inherit resource;
                  };
                }) config.reject;
            }
          ];
    }
  );

  mutatingOperations =
    steps:
    lib.unique (
      lib.concatMap (
        step:
        lib.concatMap (op: lib.filter (o: !(builtins.elem o readOnlyOperations)) (lib.attrNames op)) (
          (step.try or [ ]) ++ (step.catch or [ ]) ++ (step.finally or [ ])
        )
      ) steps
    );
}
