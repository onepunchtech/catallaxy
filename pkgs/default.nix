# pkgs/default.nix
#
# All package derivations for catallaxy.

{
  self,
  lib,
  pkgs,
  craneLib,
  rustToolchain,
  cataCharts ? null,
  k8sSpecs ? null,
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

  # Option docs — auto-generated from Nix module system
  optionDocs =
    if cataCharts != null && k8sSpecs != null then
      let
        raw = import ../lib/docs/options.nix {
          inherit
            lib
            pkgs
            cataCharts
            k8sSpecs
            ;
          sourceRoot = toString self;
        };
      in
      pkgs.runCommand "catallaxy-option-docs" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        python3 ${../lib/docs/render.py} \
          ${raw.json}/share/doc/nixos/options.json \
          $out
      ''
    else
      null;

  # Documentation site
  docs =
    if optionDocs != null then
      pkgs.runCommand "catallaxy-docs"
        {
          nativeBuildInputs = [
            pkgs.mdbook
            pkgs.mdbook-mermaid
          ];
        }
        ''
          cp -r ${../docs/book} src
          chmod -R u+w src
          mkdir -p src/src/reference/options/components
          cp ${optionDocs}/lab.md src/src/reference/options/
          cp ${optionDocs}/cluster.md src/src/reference/options/
          cp ${optionDocs}/components/*.md src/src/reference/options/components/
          mdbook-mermaid install src
          mdbook build src -d $out
        ''
    else
      null;

in
{
  inherit
    tools
    cata
    cataWrapped
    mkScript
    optionDocs
    docs
    ;
}
