{ lib }:

let
  kinds = import ../../modules/lab/planner/kinds { inherit lib; };

  oneLine =
    text:
    lib.concatStringsSep " " (
      lib.filter (s: s != "") (
        map lib.trim (lib.splitString "\n" (builtins.replaceStrings [ "|" ] [ "\\|" ] text))
      )
    );

  renderDefault =
    option:
    if !(option ? default) then
      "_required_"
    else
      "`" + lib.generators.toPretty { multiline = false; } option.default + "`";

  paramRow =
    name: option:
    "| `${name}` | ${option.type.description} | ${renderDefault option} | ${
      oneLine (option.description or "")
    } |";

  paramsTable =
    kind:
    if kind.params.options == { } then
      "Takes no params."
    else
      lib.concatStringsSep "\n" (
        [
          "| Param | Type | Default | Description |"
          "| ----- | ---- | ------- | ----------- |"
        ]
        ++ lib.mapAttrsToList paramRow kind.params.options
      );

  retryLabel = {
    idempotent = "Retried on failure.";
    oneShot = "**Not retried**: repeating it corrupts state.";
    destructive = "**Not retried**: repeating it extends the damage.";
  };

  factsLine =
    kind:
    let
      directions = lib.concatStringsSep " and " kind.directions;
      plural = if lib.length kind.directions > 1 then "plans" else "plan";
      dryRun = if kind.dryRunSafe then "Read-only, so `--dry-run` executes it." else "";
      dials =
        if kind.dialsLabEndpoints then
          "Dials a lab endpoint from the host, so it lands after any step publishing `host/lab-reachable`."
        else
          "";
    in
    lib.concatStringsSep " " (
      lib.filter (s: s != "") [
        "Runs in the ${directions} ${plural}."
        retryLabel.${kind.idempotency}
        dryRun
        dials
      ]
    );

  section = name: kind: ''
    ## `${name}`

    ${factsLine kind}

    ${paramsTable kind}
  '';

  preamble = ''
    # Plan Step Kinds

    Generated from `modules/lab/planner/kinds/`, one file per kind. A
    `lab.steps.<n>.kind` names one of these, and the entry it names is what
    types that step's `params`, decides which plan directions it may run in,
    and tells the executor how to retry it.

    A kind that runs in both directions has no default `direction`, so a
    `run-script` or `destroy-cluster` step has to say which plan it belongs
    to.

    Retry is a property of the kind, carried to the CLI on `policy.retry`.
    A step whose `policy.interactive` is true runs once regardless, because a
    retry would re-prompt someone who already answered, and
    `policy.skipIfClusterReachable` short-circuits a step whose work is
    already done, which is how a re-run skips the bootstrap half of a pivot.

    The `bootstrap-argocd-*` kinds and `verify-argocd-reachable` are variants
    of one logical step, selected by `lab.cd.bootstrap`. All three publish
    `cluster/<n>/argocd-installed`, so anchor on the token rather than on any
    one kind.

    Teardown ordering is not cosmetic: `release-cluster-cloud-resources`
    publishes `cluster/<t>/cloud-released` and `delete-managed-resource`
    requires it, because a cloud provider orphans load balancers and volumes
    whose owning cluster no longer exists.

    Every field you can set on `lab.steps.<name>` is in
    [Plan Step Options](./options/steps.md). Anchors use the grammar in
    [Anchors and Tokens](./anchors.md).
  '';

in
lib.concatStringsSep "\n" ([ preamble ] ++ lib.mapAttrsToList section kinds)
