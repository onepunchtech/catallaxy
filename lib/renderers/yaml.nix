# lib/renderers/yaml.nix
#
# YAML utilities for manifest rendering.
# Uses yq-go to convert JSON (from builtins.toJSON) to human-readable YAML.

{ lib, pkgs }:

{
  # Convert an attribute set to a human-readable YAML file.
  toYamlFile =
    name: attrs:
    pkgs.runCommand "${name}.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
        passAsFile = [ "jsonInput" ];
        jsonInput = builtins.toJSON attrs;
      }
      ''
        yq -P '.' "$jsonInputPath" > $out
      '';

  # Convert a list of attribute sets to a multi-document YAML file.
  toMultiDocYamlFile =
    name: docs:
    pkgs.runCommand "${name}.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
        passAsFile = [ "jsonInput" ];
        jsonInput = builtins.toJSON docs;
      }
      ''
        yq -P '.[]' "$jsonInputPath" | sed 's/^---$/\n---/' > $out
      '';

  # Convert a JSON file (derivation) to a human-readable YAML file.
  jsonFileToYaml =
    name: jsonFile:
    pkgs.runCommand "${name}.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        yq -P '.' ${jsonFile} > $out
      '';

  # Recursively convert all .yaml files in a directory from JSON to pretty YAML.
  # Returns a new directory derivation with converted files.
  convertDir =
    name: dir:
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        cp -r --no-preserve=mode ${dir} $out
        find $out -name '*.yaml' -type f | while read -r f; do
          yq -P -i '.' "$f" 2>/dev/null || true
        done
      '';
}
