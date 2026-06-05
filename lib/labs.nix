# Lab evaluation helpers.
#
# mkLab: evaluate a lab from user-provided modules.
# discoverExampleLabs: auto-discover example lab definitions from examples/labs/envs/.
{
  lib,
  pkgs,
  pureLib,
  cataCharts,
  k8sSpecs,
  modulesPath,
  examplesPath,
}:

let
  # Evaluate a lab: run modules through evalModule with catallaxy defaults
  mkLab =
    { modules }:
    pureLib.evalModule {
      modules = [
        modulesPath
        {
          _module.args.cataCharts = cataCharts;
          _module.args.k8sSpecs = k8sSpecs;
        }
      ]
      ++ modules;
      specialArgs = { inherit lib pkgs; };
    };

  # Auto-discover example lab definitions from examples/labs/envs/*.nix
  # Each env file is composed with the base lab definition.
  # Lab names use dotted notation: homelab.local, homelab.staging, homelab.prod
  discoverExampleLabs =
    let
      entries = builtins.readDir (examplesPath + "/envs");
      isEnvFile = name: type: type == "regular" && lib.hasSuffix ".nix" name;
      envFiles = lib.filterAttrs isEnvFile entries;
    in
    lib.mapAttrs' (
      filename: _:
      let
        envName = lib.removeSuffix ".nix" filename;
      in
      lib.nameValuePair "homelab.${envName}" (mkLab {
        modules = [
          (examplesPath + "/labs/default.nix")
          (examplesPath + "/envs/${filename}")
        ];
      })
    ) envFiles;

  # Config for the K8s type generator CLI command
  k8sTypegenConfig = {
    outputDir = "modules/lab/cluster/lib/kubernetes/generated";
    k8sVersions = lib.mapAttrs (_: spec: "${spec}") k8sSpecs.specs;
    crds = k8sSpecs.crds;
  };

in
{
  inherit mkLab discoverExampleLabs k8sTypegenConfig;
}
