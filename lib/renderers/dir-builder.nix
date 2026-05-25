# lib/renderers/dir-builder.nix
#
# Directory structure builders for manifest output packages.
# Assembles derivations into organized directory trees.

{
  lib,
  pkgs,
  yamlUtil,
}:

let
  inherit (lib)
    concatStringsSep
    mapAttrsToList
    imap0
    fixedWidthString
    ;

in
{
  # Build a directory tree from an attrset of { "relative/path" = source; }.
  # Source can be a derivation (file or directory) or a string.
  #
  # Example:
  #   buildDir "my-output" {
  #     "apps/crds.yaml" = someDerivation;
  #     "phases/crds" = phasePackage;  # directory derivation copied into phases/crds/
  #   }
  buildDir =
    name: entries:
    pkgs.runCommand name { } ''
      mkdir -p $out
      ${concatStringsSep "\n" (
        mapAttrsToList (
          path: source:
          if lib.isDerivation source then
            ''
              if [ -d "${source}" ]; then
                mkdir -p "$out/${path}"
                cp -r ${source}/* "$out/${path}/" 2>/dev/null || true
              else
                mkdir -p "$out/$(dirname "${path}")"
                cp ${source} "$out/${path}"
              fi
            ''
          else if builtins.isString source then
            ''
              mkdir -p "$out/$(dirname "${path}")"
              cat > "$out/${path}" <<'ENDOFFILE'
              ${source}
              ENDOFFILE
            ''
          else
            throw "dir-builder: unsupported source type for path ${path}"
        ) entries
      )}
    '';

  # Build ordered phase directories: 00-crds/, 01-namespaces/, etc.
  # Takes phaseOrder (list of names) and phases (attrset with .package per phase).
  # Converts all YAML files to human-readable format.
  buildOrderedDirs =
    name: phaseOrder: phases:
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p $out
        ${concatStringsSep "\n" (
          imap0 (
            i: phaseName:
            let
              phase = phases.${phaseName};
              prefix = fixedWidthString 2 "0" (toString i);
            in
            ''
              mkdir -p "$out/${prefix}-${phaseName}"
              if [ -d "${phase.package}" ]; then
                cp -r --no-preserve=mode ${phase.package}/* "$out/${prefix}-${phaseName}/" 2>/dev/null || true
              else
                cp --no-preserve=mode ${phase.package} "$out/${prefix}-${phaseName}/manifests.yaml"
              fi

              # Convert JSON-as-YAML to human-readable YAML
              find "$out/${prefix}-${phaseName}" -name '*.yaml' -type f | while read -r f; do
                yq -P -i '.' "$f" 2>/dev/null || true
              done
            ''
          ) phaseOrder
        )}

        # Write phase ordering metadata
        cat > $out/.phase-order <<'EOF'
        ${concatStringsSep "\n" phaseOrder}
        EOF

        # Write per-phase CRD wait metadata
        ${concatStringsSep "\n" (
          imap0 (
            i: phaseName:
            let
              phase = phases.${phaseName};
              prefix = fixedWidthString 2 "0" (toString i);
              crdNames = phase.waitForCRDs or false;
              names = phase.crdNames or [ ];
            in
            if crdNames && names != [ ] then
              ''
                cat > "$out/${prefix}-${phaseName}/.crd-wait" <<'CRDEOF'
                ${concatStringsSep "\n" names}
                CRDEOF
              ''
            else
              ""
          ) phaseOrder
        )}
      '';
}
