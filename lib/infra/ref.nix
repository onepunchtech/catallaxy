{ lib }:

let
  marker = "infra-ref";
in
rec {
  ref = resource: output: {
    _type = marker;
    inherit resource output;
  };

  isRef = v: builtins.isAttrs v && (v._type or null) == marker;

  refsIn =
    value:
    if isRef value then
      [ value ]
    else if builtins.isAttrs value then
      lib.concatMap refsIn (builtins.attrValues value)
    else if builtins.isList value then
      lib.concatMap refsIn value
    else
      [ ];

  show = r: "${r.resource}.${r.output}";

  renameRefs =
    rename: value:
    if isRef value then
      value // { resource = rename value.resource; }
    else if builtins.isAttrs value then
      lib.mapAttrs (_: renameRefs rename) value
    else if builtins.isList value then
      map (renameRefs rename) value
    else
      value;

  # What a reference becomes in the rendered stack.
  #
  # Inside one stack it is an interpolation through the target's type, which
  # is why nothing referring to a bucket has to repeat that it is a bucket.
  # Across stacks the target's attributes are not in scope, so it reads the
  # producer's state instead, and the producer already emits an output for
  # every attribute it declares.
  resolveWith =
    {
      resources,
      crossStack ? null,
    }:
    let
      go =
        value:
        if isRef value then
          let
            resource =
              resources.${value.resource} or (throw ''
                A reference names '${show value}', and no resource called
                '${value.resource}' is declared. The lab declares: ${
                  if resources == { } then "none" else lib.concatStringsSep ", " (lib.attrNames resources)
                }.

                Rendering resolves a reference through the target's own type,
                so there is nothing to render this as. The assertion that
                would normally say this reads the same table; it is repeated
                here because rendering can be forced first, and an attribute
                error naming neither the reference nor the lab is not an
                answer.
              '');

            producer = if crossStack == null then null else crossStack.stackOf value.resource;
          in
          if crossStack != null && producer != crossStack.here then
            "\${data.terraform_remote_state.${producer}.outputs.${value.resource}_${value.output}}"
          else
            "\${${resource.type}.${value.resource}.${value.output}}"
        else if builtins.isAttrs value then
          lib.mapAttrs (_: go) value
        else if builtins.isList value then
          map go value
        else
          value;
    in
    go;

  refType = lib.mkOptionType {
    name = "infraRef";
    description = "a reference to an output of a provisioned resource";
    check = isRef;
    merge = lib.options.mergeEqualOption;
  };
}
