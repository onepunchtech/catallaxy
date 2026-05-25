# lib/renderers/fleet.nix
#
# Fleet manifest renderer.
# Produces directories per phase, each containing a fleet.yaml with
# dependsOn for ordering and the raw manifests.
#
# Output structure:
#   <clusterName>/
#     [prefix-]crds/
#       fleet.yaml
#       manifests.yaml
#     [prefix-]namespaces/
#       fleet.yaml
#       manifests.yaml
#     ...
#     .deploy-strategy

{
  lib,
  pkgs,
  dirBuilder,
  yamlUtil,
  prefixUtil,
}:

{
  clusterName,
  prefix ? "",
  labNamespaces ? [ ],
  phases,
  phaseOrder,
  deployConfig,
}:

let
  inherit (lib) concatStringsSep mapAttrsToList;

  # Apply prefix to phase/bundle names
  pfx = name: prefixUtil.phaseName prefix name;

  # Generate a fleet.yaml for a phase
  mkFleetYaml =
    phaseName:
    let
      phase = phases.${phaseName};

      # Fleet dependsOn references other bundles — prefix them too
      dependsOn = map (dep: {
        name = pfx dep;
      }) phase.dependsOn;

      fleetConfig = {
        defaultNamespace = "default";
      }
      // lib.optionalAttrs (dependsOn != [ ]) {
        inherit dependsOn;
      }
      // lib.optionalAttrs phase.keepResources {
        keepResources = true;
      };
    in
    fleetConfig;

  # Build each phase directory with fleet.yaml + manifests
  phasesDrv =
    pkgs.runCommand "fleet-${clusterName}-phases"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p $out
        ${concatStringsSep "\n" (
          map (
            phaseName:
            let
              phase = phases.${phaseName};
              fleetConfig = mkFleetYaml phaseName;
              dirName = pfx phaseName;
            in
            ''
              mkdir -p "$out/${dirName}"

              # Write fleet.yaml
              echo '${builtins.toJSON fleetConfig}' | yq -P '.' > "$out/${dirName}/fleet.yaml"

              # Copy rendered manifests
              if [ -d "${phase.package}" ]; then
                cp -r --no-preserve=mode ${phase.package}/* "$out/${dirName}/" 2>/dev/null || true
              else
                cp --no-preserve=mode ${phase.package} "$out/${dirName}/manifests.yaml"
              fi

              # Convert to human-readable YAML
              find "$out/${dirName}" -name '*.yaml' -not -name 'fleet.yaml' -type f | while read -r f; do
                yq -P -i '.' "$f" 2>/dev/null || true
              done

              # Apply prefix to resource names
              ${prefixUtil.applyToDir { inherit prefix labNamespaces; } "$out/${dirName}"}
            ''
          ) phaseOrder
        )}
      '';

in
pkgs.runCommand "fleet-${clusterName}" { } ''
  mkdir -p "$out/${clusterName}"
  cp -r ${phasesDrv}/* "$out/${clusterName}/"
  echo "fleet" > "$out/${clusterName}/.deploy-strategy"
''
