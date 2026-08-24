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
  tools =
    with pkgs;
    [
      talosctl
      k3d
      kubectl
      kapp
      kyverno-chainsaw
      kubernetes-helm
      jq
      yq-go
      docker-client
      coreutils
      openssl
      sops
      age
      crane
      gzip
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [
      pkgs.nssTools
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      pkgs.colima
    ];

  cata = import ./cli.nix {
    inherit
      lib
      pkgs
      craneLib
      rustToolchain
      ;
  };

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

  cataWrapped = pkgs.writeShellApplication {
    name = "cata";
    runtimeInputs = tools ++ [
      cata
      pkgs.nix
    ];
    text = ''
      export CATALLAXY_SYSTEM_CA_BUNDLE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      exec ${cata}/bin/cata "$@"
    '';
  };

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
      pkgs.runCommand "catallaxy-option-docs" { nativeBuildInputs = [ cata ]; } ''
        cata-build docs render ${raw.json}/share/doc/nixos/options.json \
          ${../docs/book/src/SUMMARY.md} $out
      ''
    else
      null;

  stepKindDocs = pkgs.writeText "step-kinds.md" (import ../lib/docs/step-kinds.nix { inherit lib; });

  e2e = import ./e2e.nix { inherit lib pkgs cataWrapped; };
  e2e-all = import ./e2e-all.nix { inherit lib pkgs e2e; };
  refresh-digests = import ./refresh-digests.nix { inherit lib pkgs; };

  siteUrl = "https://onepunchtech.github.io/catallaxy";

  docs =
    if optionDocs != null then
      pkgs.runCommand "catallaxy-docs"
        {
          nativeBuildInputs = [
            pkgs.mdbook
            pkgs.mdbook-mermaid
            cata
          ];
        }
        ''
          cp -r ${../docs/book} src
          chmod -R u+w src
          cp -r ${optionDocs}/. src/src/reference/
          chmod -R u+w src/src/reference
          cp ${stepKindDocs} src/src/reference/step-kinds.md
          cp ${../CHANGELOG.md} src/src/changelog.md
          chmod u+w src/src/changelog.md
          mv src/src/reference/SUMMARY.md src/src/SUMMARY.md
          rm -f src/src/reference/undescribed.txt
          mdbook-mermaid install src
          mdbook build src -d $out

          cata-build docs llms src/src ${siteUrl} $out
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
    e2e
    e2e-all
    refresh-digests
    optionDocs
    stepKindDocs
    docs
    ;
}
