{ lib, pkgs }:

let
  yamlUtil = import ./yaml.nix { inherit lib pkgs; };
in
{
  mkVerifyTest =
    {
      labName,
      clusterName,
      checks,
    }:
    let
      steps = lib.concatMap (check: check.out.steps) (
        lib.attrValues (lib.filterAttrs (_: c: c.out.steps != [ ]) checks)
      );

      test = {
        apiVersion = "chainsaw.kyverno.io/v1alpha1";
        kind = "Test";
        metadata.name = lib.replaceStrings [ "." ] [ "-" ] "${labName}-${clusterName}";
        spec = {
          cluster = clusterName;
          namespace = "default";
          skipDelete = true;
          inherit steps;
        };
      };
    in
    pkgs.runCommand "verify-${labName}-${clusterName}" { } ''
      mkdir -p $out/${clusterName}
      ${lib.optionalString (
        steps != [ ]
      ) "cp ${yamlUtil.toYamlFile "chainsaw-test" test} $out/${clusterName}/chainsaw-test.yaml"}
    '';
}
