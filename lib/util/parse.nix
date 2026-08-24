{ lib }:

# Reading numbers out of strings, without a character class.
#
# Several places in the tree need to know whether a piece of a version, a tag
# or a duration is a number, and each of them used to answer with its own
# `[0-9]+` inside a larger pattern. A pattern that says "these characters are
# a number" is a second, worse implementation of `lib.toInt` that can drift
# from it; asking `lib.toInt` and treating a throw as "no" cannot.

{
  # The integer a string holds, or null when it does not hold one.
  # `lib.toInt` throws on anything it cannot read, and a throw is exactly the
  # answer we want, so tryEval turns it into a value.
  toIntOrNull =
    s:
    if !(builtins.isString s) then
      null
    else
      let
        read = builtins.tryEval (lib.toInt s);
      in
      if read.success then read.value else null;
}
