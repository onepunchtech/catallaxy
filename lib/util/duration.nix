{ lib }:

# One reading of `5m`.
#
# There used to be two: `lib/util/wait.nix` and the external-dns floe each
# carried the same `([0-9]+)(s|m|h)` and disagreed about what a string that
# did not match meant. wait.nix threw; external-dns silently substituted 60
# and carried on, so a typo in `floes.external-dns.interval` reached a
# reconcile deadline computed from a number nobody wrote. A grammar with two
# implementations has two failure modes, which is one more than a grammar
# should have.
#
# The parse is structural rather than a pattern: a duration is an integer and
# a unit, so take the last character as the unit and read what is left as a
# number. `lib.toInt` throwing is the definition of "not a number", so that is
# the test rather than a character class that has to be kept in step with it.

let
  inherit (import ./parse.nix { inherit lib; }) toIntOrNull;

  # Seconds per unit. Adding a unit here is the whole change; nothing else
  # enumerates them.
  unitSeconds = {
    s = 1;
    m = 60;
    h = 3600;
    d = 86400;
  };

  units = lib.attrNames unitSeconds;

  # `{ value; unit; seconds; }`, or null when the string is not a duration.
  # Callers that want an error pick the message themselves — the option type
  # below and `toSeconds` want to say different things.
  parse =
    s:
    let
      width = builtins.stringLength s;
      unit = builtins.substring (width - 1) 1 s;
      magnitude = toIntOrNull (builtins.substring 0 (width - 1) s);
    in
    if width < 2 || !(unitSeconds ? ${unit}) || magnitude == null || magnitude < 0 then
      null
    else
      {
        value = magnitude;
        inherit unit;
        seconds = magnitude * unitSeconds.${unit};
      };

  isDuration = s: builtins.isString s && parse s != null;

  describe = ''a whole number of ${lib.concatStringsSep "/" units} (for example "30s", "5m", "1h")'';

in
{
  inherit parse isDuration unitSeconds;

  # The seconds a duration is worth. Throws, because every caller in the tree
  # is building a loop count or a deadline out of the answer and there is no
  # sensible number to invent when the input is not a duration.
  toSeconds =
    context: s:
    let
      parsed = parse s;
    in
    if parsed == null then
      throw "${context}: '${toString s}' is not a duration. Expected ${describe}."
    else
      parsed.seconds;

  # The type to give any option holding one of these, so a typo is refused at
  # the line that wrote it rather than at whatever later arithmetic consumed
  # it. This is the reason the check exists at all: an assertion further in
  # names a floe, and this names the option.
  type = lib.types.addCheck lib.types.str isDuration // {
    name = "duration";
    description = "duration string: ${describe}";
  };
}
