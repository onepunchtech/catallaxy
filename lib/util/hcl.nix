{ lib }:

let
  escape = lib.escape [
    "\\"
    "\""
  ];

  value =
    v:
    if builtins.isString v then
      "\"${escape v}\""
    else if builtins.isBool v then
      lib.boolToString v
    else if builtins.isInt v || builtins.isFloat v then
      toString v
    else if builtins.isList v then
      "[${lib.concatMapStringsSep ", " value v}]"
    else
      throw "hcl: a ${builtins.typeOf v} has no HCL form; use a string, number, bool, list or attrset";

  body =
    indent: attrs:
    lib.concatStrings (
      lib.mapAttrsToList (
        k: v:
        if builtins.isAttrs v then
          "${indent}${k} {\n${body (indent + "  ") v}${indent}}\n"
        else
          "${indent}${k} = ${value v}\n"
      ) attrs
    );
in
{
  inherit value body;

  # A labelled block: `seal "awskms" { … }`, `storage "raft" { … }`.
  #
  # OpenBao's config distinguishes a string from a number from a bool, and the
  # renderer this replaced put every value through `toString` inside quotes:
  # an int became a quoted string, `true` became `"1"`, `false` became `""`,
  # and a nested attrset stringified to garbage. A seal or a raft block with a
  # port or a flag in it came out wrong.
  block =
    kind: label: attrs:
    "${kind} \"${escape label}\" {\n${body "  " attrs}}\n";
}
