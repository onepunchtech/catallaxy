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
    }:
    mkIdempotentJob {
      name = "boot";
      namespace = "ns";
      inherit contentInputs podSpec;
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

  testPodSpecChangeAloneChangesTheHash = {
    expr = differentEnv.hash != base.hash;
    expected = true;
  };

  testOwnerConfigMapRecordsThisGeneration = {
    expr = (base.resources."boot-runs".data.${base.hash} or null);
    expected = "applied";
  };
}
