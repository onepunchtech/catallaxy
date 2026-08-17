{ lib, pkgs }:

let
  inherit (import ../../floe { inherit lib; }) mkFloe evalFloe;

  emptyFloe =
    {
      requiresList ? [ ],
    }:
    mkFloe {
      name = "subject";

      requires = requiresList;
      module = _: { };
    };

  clusterStub =
    { lib, ... }:
    {

      options.floes.dns.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };

  unmetResult = evalFloe {
    floe = emptyFloe { requiresList = [ "dns" ]; };
    cluster = {
      imports = [ clusterStub ];
      floes.subject.enable = true;
    };
  };

  metResult = evalFloe {
    floe = emptyFloe { requiresList = [ "dns" ]; };
    cluster = {
      imports = [ clusterStub ];
      floes.subject.enable = true;
      floes.dns.enable = true;
    };
  };

  disabledResult = evalFloe {
    floe = emptyFloe { requiresList = [ "dns" ]; };
    cluster = {
      imports = [ clusterStub ];
      floes.subject.enable = false;
    };
  };

  undeclaredPeerResult = evalFloe {
    floe = emptyFloe { requiresList = [ "totally-missing" ]; };
    cluster = {
      imports = [ clusterStub ];
      floes.subject.enable = true;
    };
  };

  failing = res: builtins.filter (a: !a.assertion) res.config.assertions;

  # A submodule in the same shape the real ones use: its own options, its
  # config behind a condition, and a bundle declared there rather than in the
  # floe's module body. It names an extra module argument so that the
  # wrapping cannot quietly stop forwarding them.
  bundleSubmodule =
    { config, lib, ... }:
    {
      config = lib.mkIf config.floes.stamped.enable {
        bundles.from-an-import.provides = [ "x" ];
      };
    };

  stampedFloe = mkFloe {
    name = "stamped";
    imports = [ bundleSubmodule ];
    module = _: {
      bundles.from-the-body.provides = [ "y" ];
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

  floeOf = res: name: (res.config.bundles.${name} or { }).floe or null;
in
lib.runTests {

  testRequiresIntrospection = {
    expr = unmetResult.config.floes.subject.requires;
    expected = [ "dns" ];
  };

  testUnmetRequiresFires = {
    expr =
      let
        f = failing unmetResult;
      in
      builtins.length f == 1
      && lib.hasInfix "subject" (builtins.head f).message
      && lib.hasInfix "dns" (builtins.head f).message;
    expected = true;
  };

  testMetRequiresSilent = {
    expr = failing metResult;
    expected = [ ];
  };

  testDisabledFloeSkipsRequires = {
    expr = failing disabledResult;
    expected = [ ];
  };

  testUndeclaredPeerStillFires = {
    expr = builtins.length (failing undeclaredPeerResult);
    expected = 1;
  };

  # Provenance is what tells `imageCompleteness` and the SBOM which floe a
  # rendered bundle belongs to. A bundle declared in an imported submodule
  # went unstamped, so both silently skipped it: forgejo and kanidm each had
  # one, and each claimed `imagesComplete`.
  testABundleFromAnImportCarriesTheStamp = {
    expr = floeOf stampedResult "from-an-import";
    expected = "stamped";
  };

  testABundleFromTheModuleBodyStillCarriesTheStamp = {
    expr = floeOf stampedResult "from-the-body";
    expected = "stamped";
  };

  # The stamp inherits the condition it was found under, so a disabled floe
  # brings neither bundle into existence rather than leaving one behind
  # carrying nothing but its provenance.
  testADisabledFloeStampsNothingFromEither = {
    expr = builtins.attrNames (disabledStampedResult.config.bundles or { });
    expected = [ ];
  };
}
