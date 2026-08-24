{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) floeOptions evalFloe;

  # A floe says what it needs on its bundles, as names the graph resolves.
  # There is no floe-level `requires`: naming another floe says which
  # implementation, where the question is which job.
  needingFloe =
    names:
    { config, ... }:
    {
      imports = [ (floeOptions { name = "subject"; }) ];

      config = lib.mkIf config.floes.subject.enable {
        floes.subject.bundles.subject.requires = names;
      };
    };

  needsResult =
    names:
    evalFloe {
      floe = needingFloe names;
      cluster.floes.subject.enable = true;
    };

  failing = res: builtins.filter (a: !a.assertion) res.config.assertions;

  # A submodule in the same shape the real ones use: its config behind a
  # condition, and a bundle declared there rather than in the floe's own
  # file. It used to need a wrapper that walked the module system's `mkIf`
  # nodes to stamp it; now it declares the bundle under the floe it belongs
  # to, so there is nothing to stamp and nothing to forward.
  bundleSubmodule =
    { config, lib, ... }:
    {
      config = lib.mkIf config.floes.stamped.enable {
        floes.stamped.bundles.from-an-import.provides = [ "x" ];
      };
    };

  stampedFloe =
    { config, ... }:
    {
      imports = [
        (floeOptions { name = "stamped"; })
        bundleSubmodule
      ];

      config = lib.mkIf config.floes.stamped.enable {
        floes.stamped.bundles.from-the-body.provides = [ "y" ];
      };
    };

  stampedResult = evalFloe {
    floe = stampedFloe;
    cluster.floes.stamped.enable = true;
  };

  disabledStampedResult = evalFloe {
    floe = stampedFloe;
    cluster.floes.stamped.enable = false;
  };

  floeOf = res: name: (res.config.bundles.${name} or { }).declaredBy or null;
in
lib.runTests {

  # There is no floe-level `requires` any more, so a floe that thought it had
  # declared a dependency would have declared nothing at all.
  testNoFloeLevelRequiresOption = {
    expr = (needsResult [ ]).config.floes.subject ? requires;
    expected = false;
  };

  testABundleCarriesTheNamesItNeeds = {
    expr = (needsResult [ "some/other/thing" ]).config.bundles.subject.requires;
    expected = [ "some/other/thing" ];
  };

  testNeedingNothingIsFine = {
    expr = failing (needsResult [ ]);
    expected = [ ];
  };

  # Provenance is what tells `imageCompleteness` and the SBOM which floe a
  # rendered bundle belongs to. A bundle declared in an imported submodule
  # used to go unstamped, so both silently skipped it: forgejo and kanidm each
  # had one, and each claimed `imagesComplete`. Declaring it under the floe
  # answers it by construction, wherever it was written.
  testABundleFromAnImportIsAttributed = {
    expr = floeOf stampedResult "from-an-import";
    expected = "stamped";
  };

  testABundleFromTheModuleBodyIsAttributed = {
    expr = floeOf stampedResult "from-the-body";
    expected = "stamped";
  };

  # A disabled floe brings neither bundle into existence. This used to be the
  # delicate part: stamping a leaf unconditionally would have materialised a
  # bundle behind a false condition carrying nothing but its provenance.
  testADisabledFloeDeclaresNothingFromEither = {
    expr = builtins.attrNames (disabledStampedResult.config.bundles or { });
    expected = [ ];
  };
}
