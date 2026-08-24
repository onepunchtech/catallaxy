{ lib }:

let
  valueAt =
    path: resource:
    lib.foldl' (
      acc: key: if builtins.isAttrs acc && acc ? ${key} then acc.${key} else null
    ) resource path;

  valueOr =
    path: fallback: resource:
    let
      v = valueAt path resource;
    in
    if v == null then fallback else v;

  listOrEmpty = path: valueOr path [ ];

  attrsOrEmpty = path: valueOr path { };

in
{
  inherit
    valueAt
    valueOr
    listOrEmpty
    attrsOrEmpty
    ;
}
