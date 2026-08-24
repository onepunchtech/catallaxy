{ lib }:

{
  contestedKeys =
    {
      floes,
      keysOf,
    }:
    let
      enabled = lib.filterAttrs (_: floe: floe.enable or false) floes;

      claims = lib.foldl' (
        acc: floeName:
        lib.foldl' (inner: key: inner // { ${key} = (inner.${key} or [ ]) ++ [ floeName ]; }) acc (
          keysOf enabled.${floeName}
        )
      ) { } (lib.attrNames enabled);
    in
    lib.filterAttrs (_: claimants: lib.length claimants > 1) claims;
}
