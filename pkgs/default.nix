# pkgs/default.nix
#
# All package derivations for catallaxy.

{
  self,
  lib,
  pkgs,
  craneLib,
  rustToolchain,
}:

let
  # Runtime tools available to the CLI and scripts
  tools =
    with pkgs;
    [
      talosctl
      k3d
      kubectl
      kapp
      kubernetes-helm
      jq
      yq-go
      docker-client
      coreutils
      openssl
      sops
      age
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [
      pkgs.nssTools # certutil for browser CA trust
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      pkgs.colima
    ];

  # Build the CLI binary
  cata = import ./cli.nix {
    inherit
      lib
      pkgs
      craneLib
      rustToolchain
      ;
  };

  # Generic runner for operational scripts
  mkScript =
    name: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = tools;
      text = ''
        set -euo pipefail
        export CATALLAXY_ROOT="${self}"
        ${text}
      '';
    };

  # Wrap cata with runtime tools in PATH
  cataWrapped = pkgs.writeShellApplication {
    name = "cata";
    runtimeInputs = tools ++ [
      cata
      pkgs.nix
    ];
    text = ''
      exec ${cata}/bin/cata "$@"
    '';
  };

in
{
  inherit
    tools
    cata
    cataWrapped
    mkScript
    ;
}
