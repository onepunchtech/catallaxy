{ lib }:

let
  inherit (import ../util/idempotent-job.nix { inherit lib; }) mkIdempotentJob;

  basePodSpec = {
    restartPolicy = "OnFailure";
    containers = [
      {
        name = "bootstrap";
        image = "alpine:3";
        env = [
          {
            name = "CLIENT_ID";
            value = "netbird-bootstrap";
          }
        ];
      }
    ];
  };

  mk =
    {
      contentInputs ? {
        a = 1;
      },
      podSpec ? basePodSpec,
      behaviourVersion ? 1,
    }:
    mkIdempotentJob {
      name = "boot";
      namespace = "ns";
      inherit contentInputs podSpec behaviourVersion;
    };

  base = mk { };
  differentContent = mk {
    contentInputs = {
      a = 2;
    };
  };

  differentEnv = mk {
    podSpec = lib.recursiveUpdate basePodSpec {
      containers = [
        (
          (builtins.head basePodSpec.containers)
          // {
            env = [
              {
                name = "CLIENT_ID";
                value = "netbird";
              }
            ];
          }
        )
      ];
    };
  };
in
lib.runTests {
  testJobNameCarriesTheHash = {
    expr = base.name == "boot-${base.hash}";
    expected = true;
  };

  testSameInputsSameHash = {
    expr = (mk { }).hash == base.hash;
    expected = true;
  };

  testContentInputsChangeTheHash = {
    expr = differentContent.hash != base.hash;
    expected = true;
  };

  # This used to assert the opposite, and that was the bug. A pod spec
  # carries the implementation: the script, the image, the env. Reformatting
  # a script or bumping a base image is not a change of desired state, and
  # re-running a bootstrap Job against a live API because of one is the
  # reason `shfmt` could not be adopted.
  testPodSpecChangeAloneDoesNotChangeTheHash = {
    expr = differentEnv.hash == base.hash;
    expected = true;
  };

  # It is still visible, though, so a reader or a check can tell a cosmetic
  # edit from a forgotten behaviourVersion bump.
  testPodSpecChangeIsStillRecorded = {
    expr =
      differentEnv.resources.${differentEnv.name}.metadata.annotations."catallaxy.io/implementation-hash"
      != base.resources.${base.name}.metadata.annotations."catallaxy.io/implementation-hash";
    expected = true;
  };

  # The escape hatch for a change the declarations cannot express: same
  # inputs, different behaviour.
  testBehaviourVersionChangesTheHash = {
    expr = (mk { behaviourVersion = 2; }).hash != base.hash;
    expected = true;
  };

  testOwnerConfigMapRecordsThisGeneration = {
    expr = (base.resources."boot-runs".data.${base.hash} or null);
    expected = "applied";
  };

  # The Job labels itself with its hash, and until this existed nothing
  # selected on it: waiting on `component=<name>` also selected every earlier
  # generation, and on the server-side-apply path nothing prunes them, so one
  # failed Job from a previous render made the wait fail forever.
  testSelectorPinsTheGeneration = {
    expr =
      let
        job = mkIdempotentJob {
          name = "bootstrap";
          namespace = "ns";
          contentInputs.repos = [ "a" ];
          podSpec = { };
        };
        other = mkIdempotentJob {
          name = "bootstrap";
          namespace = "ns";
          contentInputs.repos = [
            "a"
            "b"
          ];
          podSpec = { };
        };
      in
      [
        (
          job.selector == "app.kubernetes.io/component=bootstrap,catallaxy.io/idempotent-job-hash=${job.hash}"
        )
        (job.selector != other.selector)
        (job.resources."${job.name}".metadata.labels."catallaxy.io/idempotent-job-hash" == job.hash)
      ];
    expected = [
      true
      true
      true
    ];
  };
}
