{
  lib,
  pkgs,
  craneLib,
  rustToolchain,
}:

let
  cliSrc = lib.cleanSourceWith {
    src = ../cli;
    filter =
      path: type:
      (craneLib.filterCargoSources path type)
      || (type == "directory")
      || (
        lib.any (ext: lib.hasSuffix ext path) [
          ".json"
          ".crt"
          ".key"
        ]
        && lib.hasInfix "/tests/fixtures/" path
      )
      || (lib.hasSuffix ".nix" path && lib.hasInfix "/src/commands/templates/" path)
      # The I/O boundary test's baseline. Without it the test panics rather
      # than passing, which is the right way round, but it has to be here.
      || (lib.hasSuffix ".txt" path && lib.hasInfix "/tests/" path);
  };

  commonArgs = {
    src = cliSrc;
    strictDeps = true;
    buildInputs =
      [ ]
      ++ lib.optionals pkgs.stdenv.isDarwin [
        pkgs.libiconv
        pkgs.apple-sdk
      ];
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;

    passthru.clippy = craneLib.cargoClippy (
      commonArgs
      // {
        inherit cargoArtifacts;
        cargoClippyExtraArgs = "--all-targets -- --deny warnings";
      }
    );
  }
)
