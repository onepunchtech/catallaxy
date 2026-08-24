{ lib }:

let
  inherit (import ../../floe { inherit lib; }) evalFloe;

  floeDeclaring = spec: {
    config.bundles.probe.declaredBy = "cluster";
    config.bundles.probe.resources.d = {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata.name = "d";
      inherit spec;
    };
  };

  evaluates =
    spec:
    (builtins.tryEval (builtins.deepSeq (evalFloe { floe = floeDeclaring spec; }).manifests "ok"))
    .success;

  workload = {
    selector.matchLabels.app = "d";
    template = {
      metadata.labels.app = "d";
      spec.containers = [
        {
          name = "c";
          image = "nginx:1.27-alpine";
        }
      ];
    };
  };
in
lib.runTests {
  testAWellFormedResourceEvaluates = {
    expr = evaluates workload;
    expected = true;
  };

  testAFieldGivenTheWrongTypeFailsTheSameWayItWouldInALab = {
    expr = evaluates (workload // { replicas = "three"; });
    expected = false;
  };

  testAKindWithNoSchemaStillEvaluates = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (evalFloe {
            floe.config.bundles.probe.declaredBy = "cluster";
            floe.config.bundles.probe.resources.r = {
              apiVersion = "example.com/v1";
              kind = "SomethingNoSchemaKnows";
              metadata.name = "r";
              spec.shape = "arbitrary";
            };
          }).manifests
          "ok"
      )).success;
    expected = true;
  };
}
