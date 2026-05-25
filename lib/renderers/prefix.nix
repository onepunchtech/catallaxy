# lib/renderers/prefix.nix
#
# Shared helper for applying lab prefix to rendered YAML manifests.
# Skips CRDs (kind: CustomResourceDefinition) since their names are tied to API groups.
# Only prefixes namespace references for lab-created namespaces.

{ lib, pkgs }:

let
  inherit (lib) concatMapStringsSep;
in
{
  # Apply prefix to all metadata.name (skip CRDs) and metadata.namespace (only lab namespaces).
  # Returns a bash snippet. No-op when prefix is empty.
  applyToDir =
    {
      prefix,
      labNamespaces ? [ ],
    }:
    dir:
    if prefix == "" then
      ""
    else
      let
        # Build yq filter for namespace matching
        nsConditions = concatMapStringsSep " or " (ns: ''.metadata.namespace == "${ns}"'') labNamespaces;
        nsFilter = if nsConditions == "" then "false" else nsConditions;
      in
      ''
        find "${dir}" -name '*.yaml' -type f | while read -r f; do
          ${pkgs.yq-go}/bin/yq -P -i '
            (select(.kind != "CustomResourceDefinition" and has("metadata") and .metadata.name != null) | .metadata.name) |= "${prefix}-" + .
          ' "$f" 2>/dev/null || true

          # Prefix namespace references only for lab-owned namespaces
          ${pkgs.yq-go}/bin/yq -P -i '
            (select(has("metadata") and .metadata.namespace != null and (${nsFilter})) | .metadata.namespace) |= "${prefix}-" + .
          ' "$f" 2>/dev/null || true
        done
      '';

  # Prefix a phase name for use as fleet bundle dir / dependsOn ref
  phaseName = prefix: name: if prefix == "" then name else "${prefix}-${name}";
}
