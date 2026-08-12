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
}
