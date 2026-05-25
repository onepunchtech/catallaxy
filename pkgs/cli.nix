# pkgs/cli.nix
#
# Build the cata CLI binary using crane.

{
  lib,
  pkgs,
  craneLib,
  rustToolchain,
}:

let
  # CLI source
  cliSrc = lib.cleanSourceWith {
    src = ../cli;
    filter = path: type: (craneLib.filterCargoSources path type) || (type == "directory");
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
  }
)
