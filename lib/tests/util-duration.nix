{ lib }:

let
  duration = import ../util/duration.nix { inherit lib; };

  # What the type would say about a value, without an evalModules round trip.
  accepts = v: duration.type.check v;
in
lib.runTests {

  testSeconds = {
    expr = (duration.parse "30s").seconds;
    expected = 30;
  };

  testMinutes = {
    expr = (duration.parse "5m").seconds;
    expected = 300;
  };

  testHours = {
    expr = (duration.parse "2h").seconds;
    expected = 7200;
  };

  testDays = {
    expr = (duration.parse "1d").seconds;
    expected = 86400;
  };

  testZeroIsADuration = {
    expr = (duration.parse "0s").seconds;
    expected = 0;
  };

  testMultiDigit = {
    expr = (duration.parse "120m").seconds;
    expected = 7200;
  };

  testTheUnitAndMagnitudeSurvive = {
    expr = builtins.removeAttrs (duration.parse "15m") [ "seconds" ];
    expected = {
      value = 15;
      unit = "m";
    };
  };

  # Every one of these used to be worth 60 seconds inside the external-dns
  # floe, because its copy of the parse substituted a default rather than
  # refusing the input.
  testAnUnknownUnitIsNotADuration = {
    expr = duration.parse "5y";
    expected = null;
  };

  testABareNumberIsNotADuration = {
    expr = duration.parse "30";
    expected = null;
  };

  testABareUnitIsNotADuration = {
    expr = duration.parse "m";
    expected = null;
  };

  testEmptyIsNotADuration = {
    expr = duration.parse "";
    expected = null;
  };

  testNonNumericMagnitudeIsNotADuration = {
    expr = duration.parse "abcm";
    expected = null;
  };

  testAFloatIsNotADuration = {
    expr = duration.parse "1.5h";
    expected = null;
  };

  # `lib.toInt` reads a leading minus happily, which would have turned a
  # deadline negative rather than rejecting it.
  testANegativeIsNotADuration = {
    expr = duration.parse "-5m";
    expected = null;
  };

  testTrailingUnitOnlyCountsAtTheEnd = {
    expr = duration.parse "5m30s";
    expected = null;
  };

  testTypeAcceptsADuration = {
    expr = accepts "5m";
    expected = true;
  };

  testTypeRefusesATypo = {
    expr = accepts "5min";
    expected = false;
  };

  testTypeRefusesANonString = {
    expr = accepts 300;
    expected = false;
  };

  testToSecondsNamesWhatAskedWhenItThrows = {
    expr =
      let
        r = builtins.tryEval (duration.toSeconds "floes.example.interval" "nope");
      in
      r.success;
    expected = false;
  };

  testToSecondsPassesAGoodValueThrough = {
    expr = duration.toSeconds "floes.example.interval" "90s";
    expected = 90;
  };
}
