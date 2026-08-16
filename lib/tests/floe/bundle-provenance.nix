{ lib }:

let
  inherit (import ../../floe/bundle-provenance.nix { inherit lib; }) stampFloe;

  # The stamp is a config fragment, so what it means is only visible after the
  # module system has merged it. A false condition must produce no bundle at
  # all rather than an empty one, which is the whole reason the walk rebuilds
  # the mkIf tree instead of collecting names out of it.
  stampedNames =
    moduleOutput:
    builtins.attrNames
      (lib.evalModules {
        modules = [
          {
            options.bundles = lib.mkOption {
              type = lib.types.attrsOf (lib.types.attrsOf (lib.types.nullOr lib.types.str));
              default = { };
            };
          }
          {
            config = stampFloe {
              name = "myfloe";
              inherit moduleOutput;
            };
          }
        ];
      }).config.bundles;

  body = {
    provides = [ "x" ];
  };
in
lib.runTests {

  testAPlainBodyStampsEveryBundle = {
    expr = stampedNames {
      bundles.a = body;
      bundles.b = body;
    };
    expected = [
      "a"
      "b"
    ];
  };

  testTheStampInheritsAFalseCondition = {
    expr = stampedNames (lib.mkIf false { bundles.a = body; });
    expected = [ ];
  };

  testTheStampInheritsATrueCondition = {
    expr = stampedNames (lib.mkIf true { bundles.a = body; });
    expected = [ "a" ];
  };

  # A floe writes its bundles across several conditional fragments; gateway
  # and cert-manager each do this a dozen times.
  testEachBranchOfAMergeIsStampedUnderItsOwnCondition = {
    expr = stampedNames (
      lib.mkMerge [
        (lib.mkIf true { bundles.on = body; })
        (lib.mkIf false { bundles.off = body; })
        { bundles.always = body; }
      ]
    );
    expected = [
      "always"
      "on"
    ];
  };

  # The condition can sit on the bundle rather than on the fragment holding
  # it, and the stamp has to inherit it either way or it materialises a
  # bundle carrying nothing but a floe name.
  testAConditionOnTheBundleItselfIsInherited = {
    expr = stampedNames {
      bundles.on = lib.mkIf true body;
      bundles.off = lib.mkIf false body;
    };
    expected = [ "on" ];
  };

  testAFloeThatDeclaresNoBundlesStampsNothing = {
    expr = stampedNames { floes.other.enable = true; };
    expected = [ ];
  };

  # `mapAttrs` does not force values, so a bundle set built by a function is
  # stamped without its bodies being evaluated.
  testAComputedBundleSetIsStamped = {
    expr = stampedNames {
      bundles = lib.listToAttrs (
        map (n: lib.nameValuePair n body) [
          "one"
          "two"
        ]
      );
    };
    expected = [
      "one"
      "two"
    ];
  };

  testTheStampIsTheFloeName = {
    expr =
      (lib.evalModules {
        modules = [
          {
            options.bundles = lib.mkOption {
              type = lib.types.attrsOf (lib.types.attrsOf (lib.types.nullOr lib.types.str));
              default = { };
            };
          }
          {
            config = stampFloe {
              name = "myfloe";
              moduleOutput.bundles.a = body;
            };
          }
        ];
      }).config.bundles.a.floe;
    expected = "myfloe";
  };
}
