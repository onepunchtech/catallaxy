{ config, lib, ... }:

let
  inherit (import ../../lib/floe/collisions.nix { inherit lib; }) contestedKeys;

  floes = config.lab.floes or { };

  enabled = lib.filterAttrs (_: floe: floe.enable or false) floes;

  from = channel: map (floe: floe.${channel}) (lib.attrValues enabled);

  contested = keysOf: contestedKeys { inherit floes keysOf; };

  categoryAndName =
    floe:
    lib.concatMap (category: map (name: "${category} ${name}") (lib.attrNames floe.ops.${category})) (
      lib.attrNames floe.ops
    );

  refusals =
    {
      what,
      keysOf,
      why,
    }:
    lib.mapAttrsToList (key: claimants: {
      assertion = false;
      message = ''
        ${what} '${key}' is declared by ${
          lib.concatStringsSep " and " (map (n: "`lab.floes.${n}`") claimants)
        }.

        ${why}
      '';
    }) (contested keysOf);
in
{
  config.lab.steps = lib.mkMerge (from "steps");
  config.lab.ops.commands = lib.mkMerge (from "ops");
  config.lab.lint.checks = lib.mkMerge (from "lint");
  config.lab.verify.checks = lib.mkMerge (from "verify");

  config.lab.assertions =
    refusals {
      what = "lab step";
      keysOf = floe: lib.attrNames floe.steps;
      why = ''
        Lab steps share one namespace, so the second does not merge with the
        first, it collides on whichever field the two disagree about and the
        module system names neither floe.

        Rename one. What another step waits on is a token in `provides`, not
        a step's key, so both may still publish the same token.
      '';
    }
    ++ refusals {
      what = "lab ops command";
      keysOf = categoryAndName;
      why = ''
        A category and a name together are how the generated tool addresses
        a command, so the second publisher collides with the first rather
        than adding to it.

        Give one its own category. Two floes may both publish a `status`;
        what they may not do is both publish the same pair.
      '';
    }
    ++ refusals {
      what = "lab lint check";
      keysOf = floe: lib.attrNames floe.lint;
      why = "Rename one. Checks are addressed by name and nothing else.";
    }
    ++ refusals {
      what = "lab verify check";
      keysOf = floe: lib.attrNames floe.verify;
      why = "Rename one. Checks are addressed by name and nothing else.";
    };
}
