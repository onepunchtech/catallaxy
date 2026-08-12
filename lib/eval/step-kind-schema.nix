{ lib }:

let
  kinds = import ../../modules/lab/planner/kinds { inherit lib; };

  sampleFor =
    kindName: fieldName: type:
    let
      elemType = type.nestedTypes.elemType or null;
    in
    if type.name == "str" then
      "conformance-sample"
    else if type.name == "int" || type.name == "signedInt" then
      1
    else if type.name == "bool" then
      true
    else if type.name == "nullOr" then
      sampleFor kindName fieldName elemType
    else if type.name == "listOf" then
      [ ]
    else if type.name == "attrsOf" || type.name == "submodule" then
      { }
    else
      throw ''
        ${kindName}.params.${fieldName} has type '${type.name}', which the
        step-kind schema emitter cannot sample. Teach `sampleFor` in
        lib/eval/step-kind-schema.nix how to build a value of it, so the
        conformance check can keep exercising this field.
      '';

  fieldOf =
    kindName: fieldName: option:
    if !(option ? type) then
      throw "${kindName}.params.${fieldName} is not an option; kind params must be a flat attrset of mkOption"
    else
      {
        required = !(option ? default);
        sample = sampleFor kindName fieldName option.type;
      };

  expectedFields = [
    "dialsLabEndpoints"
    "directions"
    "dryRunSafe"
    "idempotency"
    "params"
  ];

  schemaOf =
    kindName: kind:
    if lib.attrNames kind != expectedFields then
      throw ''
        ${kindName} declares ${lib.concatStringsSep ", " (lib.attrNames kind)}.
        A kind declares exactly ${lib.concatStringsSep ", " expectedFields}, so
        that every new kind has to answer the same questions and a misspelled
        field cannot go unread.
      ''
    else if kind.params.options ? kind then
      throw ''
        ${kindName} declares a param named `kind`. The plan wire format tags a
        step's params with its kind, so that param would overwrite the tag and
        the CLI would dispatch on it. Name it `resourceKind`, or whatever it
        is the kind of.
      ''
    else
      {
        inherit (kind) directions idempotency dryRunSafe;
        params = lib.mapAttrs (fieldOf kindName) kind.params.options;
      };
in
lib.mapAttrs schemaOf kinds
