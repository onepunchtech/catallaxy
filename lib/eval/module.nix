{ lib }:

{

  evalModule =
    {
      modules,
      specialArgs ? { },
    }:
    let
      result = lib.evalModules {
        inherit modules specialArgs;
      };

      cfg = result.config;

      failedAssertions = builtins.filter (a: !a.assertion) (cfg.assertions or [ ]);

      assertionMessages = map (a: a.message) failedAssertions;
    in
    if failedAssertions != [ ] then
      throw ("Failed assertions:\n" + lib.concatStringsSep "\n" (map (msg: "- ${msg}") assertionMessages))
    else
      result;
}
