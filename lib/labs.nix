{
  lib,
  pkgs,
  pureLib,
  cataCharts,
  k8sSpecs,
  modulesPath,
  examplesPath,

  tools ? [ ],
  cataWrapped ? null,
}:

let

  mkLab =
    { modules }:
    pureLib.evalModule {
      modules = [
        modulesPath
        {
          _module.args.cataCharts = cataCharts;
          _module.args.k8sSpecs = k8sSpecs;
          _module.args.k8sHelpers = import ./k8s-helpers.nix { inherit lib; };
          _module.args.contracts = import ./contracts { inherit lib; };
        }
      ]
      ++ modules;
      specialArgs = { inherit lib pkgs; };
    };

  discoverExampleLabs =
    let
      isNixFile = name: type: type == "regular" && lib.hasSuffix ".nix" name;

      labDirs = lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (examplesPath + "/${name}/labs/default.nix")
      ) (builtins.readDir examplesPath);

      labsIn =
        labName: _:
        let
          envDir = examplesPath + "/${labName}/envs";
          envFiles = lib.filterAttrs isNixFile (builtins.readDir envDir);
        in
        lib.mapAttrs' (
          filename: _:
          lib.nameValuePair "${labName}.${lib.removeSuffix ".nix" filename}" (mkLab {
            modules = [
              (examplesPath + "/${labName}/labs/default.nix")
              (envDir + "/${filename}")
            ];
          })
        ) envFiles;
    in
    lib.foldl' lib.mergeAttrs { } (lib.mapAttrsToList labsIn labDirs);

  mkLabShell =
    lab:
    let
      out = lab.config.lab.out;
      name = lab.config.lab.name;
    in
    pkgs.mkShell (
      out.shell.variables
      // {
        packages = tools ++ out.shell.packages ++ lib.optional (cataWrapped != null) cataWrapped;
        shellHook = ''
          if trust_env="$(cata lab env ${lib.escapeShellArg name} 2>/dev/null)"; then
            eval "$trust_env"
            echo "catallaxy: lab '${name}' CA trusted in this shell"
          else
            echo "catallaxy: lab '${name}' has no CA yet; run 'cata lab up' for trusted *.${
              lab.config.lab.dns.zone or "<zone>"
            }"
          fi
        '';
      }
    );

  k8sTypegenConfig = {
    outputDir = "modules/lab/cluster/lib/kubernetes/generated";
    k8sVersions = lib.mapAttrs (_: spec: "${spec}") k8sSpecs.specs;
    crds = k8sSpecs.crds;
  };

in
{
  inherit
    mkLab
    mkLabShell
    discoverExampleLabs
    k8sTypegenConfig
    ;
}
