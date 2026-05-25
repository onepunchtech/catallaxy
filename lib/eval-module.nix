# lib/eval-module.nix
#
# General-purpose module evaluator with assertion checking.
# Similar to NixOS's evalModules but customized for catallaxy.

{ lib }:

{
  # Evaluate modules with assertion checking.
  #
  # Returns the full evalModules result ({ config, options, ... }).
  # Throws if any assertions fail.
  #
  # Arguments:
  #   modules:     list of modules to evaluate
  #   specialArgs: extra arguments passed to all modules (e.g. lib, pkgs)
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
