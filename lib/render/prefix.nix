{ lib, pkgs }:

let
  inherit (lib) concatMapStringsSep;
in
{

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

        nsConditions = concatMapStringsSep " or " (ns: ''.metadata.namespace == "${ns}"'') labNamespaces;
        nsFilter = if nsConditions == "" then "false" else nsConditions;
      in
      ''
        find "${dir}" -name '*.yaml' -type f | while read -r f; do
          ${pkgs.yq-go}/bin/yq -P -i '
            (select(.kind != "CustomResourceDefinition" and has("metadata") and .metadata.name != null) | .metadata.name) |= "${prefix}-" + .
          ' "$f" 2>/dev/null || true

          ${pkgs.yq-go}/bin/yq -P -i '
            (select(has("metadata") and .metadata.namespace != null and (${nsFilter})) | .metadata.namespace) |= "${prefix}-" + .
          ' "$f" 2>/dev/null || true
        done
      '';

  prefixed = prefix: name: if prefix == "" then name else "${prefix}-${name}";
}
