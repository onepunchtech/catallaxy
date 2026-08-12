{ lib, pkgs }:

let

  stripEmptyMetadataFields' =
    preserveEmptyMeta: val:
    let
      recurse = stripEmptyMetadataFields' preserveEmptyMeta;
    in
    if lib.isAttrs val then
      let
        recursed = lib.mapAttrs (_: recurse) (lib.filterAttrs (_: v: v != null) val);
        cleanMetadata =
          m:
          lib.filterAttrs (
            n: v:
            !((n == "finalizers" || n == "ownerReferences") && lib.isList v && v == [ ])
            && !(!preserveEmptyMeta && (n == "labels" || n == "annotations") && lib.isAttrs v && v == { })
          ) m;
      in
      if recursed ? metadata && lib.isAttrs recursed.metadata then
        recursed // { metadata = cleanMetadata recursed.metadata; }
      else
        recursed
    else if lib.isList val then
      map recurse val
    else
      val;

  stripEmptyMetadataFields = stripEmptyMetadataFields' true;
in
{
  inherit stripEmptyMetadataFields;

  toYamlFile =
    name: attrs:
    pkgs.runCommand "${name}.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
        passAsFile = [ "jsonInput" ];
        jsonInput = builtins.toJSON (stripEmptyMetadataFields attrs);
      }
      ''
        yq -P '.' "$jsonInputPath" > $out
      '';

  toMultiDocYamlFile =
    name: docs:
    pkgs.runCommand "${name}.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
        passAsFile = [ "jsonInput" ];
        jsonInput = builtins.toJSON (stripEmptyMetadataFields docs);
      }
      ''
        yq -P '.[]' "$jsonInputPath" | sed 's/^---$/\n---/' > $out
      '';

  jsonFileToYaml =
    name: jsonFile:
    pkgs.runCommand "${name}.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        yq -P '.' ${jsonFile} > $out
      '';

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
