{
  lib,
  pkgs,
  k8sTypegenConfig,
}:

let
  python = pkgs.python3.withPackages (p: [ p.pyyaml ]);

  crdFiles = lib.attrValues k8sTypegenConfig.crds;

  forVersion =
    version: swagger:
    pkgs.runCommand "k8s-json-schemas-${version}"
      {
        nativeBuildInputs = [ python ];
      }
      ''
        mkdir -p "$out"
        python3 ${./build-schemas.py} "$out" ${swagger} ${
          lib.concatStringsSep " " (map (f: "${f}") crdFiles)
        }
      '';
in
lib.mapAttrs forVersion k8sTypegenConfig.k8sVersions
