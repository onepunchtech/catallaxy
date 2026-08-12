{ lib }:

{
  mkPreserveRuntimePatches =
    resources:
    map (r: {
      target = { inherit (r) kind name; };
      patch = ''
        apiVersion: v1
        kind: ${r.kind}
        metadata:
          name: ${r.name}
          annotations:
            kapp.k14s.io/update-strategy: skip
      '';
    }) resources;
}
