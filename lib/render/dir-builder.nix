{
  lib,
  pkgs,
  yamlUtil,
  waitImages ? { },
}:

let
  inherit (lib)
    concatStringsSep
    mapAttrsToList
    imap0
    fixedWidthString
    ;

  waitLib = import ../util/wait.nix {
    inherit lib;
    images = waitImages;
  };

  nativeProbeKinds = [
    "condition"
    "jsonpath"
    "exists"
    "kubectl-wait"
    "script"
  ];

  normalizeProbe =
    bundleKey: probe:
    if probe == null then
      null
    else if builtins.elem (probe.kind or "") nativeProbeKinds then
      probe
    else
      let
        c = waitLib.renderProbe probe;
      in
      if c ? volumeMounts then
        throw ''
          dir-builder: readyProbe for bundle '${bundleKey}' uses kind
          '${probe.kind}' with `caBundleMount`, which needs a pod-level
          volume the one-shot probe Pod has no way to define. Use this
          shape as a `mkWaitInitContainer` inside the bundle's own
          workload (where the volume exists), and give the bundle a
          kubectl-native readyProbe instead.
        ''
      else
        {
          kind = "pod";
          inherit (c) image command;
          args = c.args or [ ];
          namespace = probe.namespace or null;
          timeout = probe.timeout or null;
        };

in
{

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

  buildWaveDirs =
    name: packages: waves:
    let
      sanitize = key: builtins.replaceStrings [ "/" ] [ "__" ] key;
      waveIndex = lib.listToAttrs (
        lib.concatLists (
          imap0 (
            i: bundles:
            map (b: {
              name = b.name;
              value = i;
            }) bundles
          ) waves
        )
      );
      dirOf =
        key:
        let
          i = waveIndex.${key} or null;
        in
        if i == null then null else "${fixedWidthString 2 "0" (toString i)}-wave/${sanitize key}";

      waveMeta = {
        waves = imap0 (i: bundles: {
          index = i;
          bundles = lib.filter (v: v != null) (
            map (
              b:
              let
                dir = dirOf b.name;
              in
              if dir == null then
                null
              else
                {
                  key = b.name;
                  inherit dir;
                  readyProbe = normalizeProbe b.name (b.readyProbe or null);
                  requires = b.requires or [ ];
                  provides = b.provides or [ ];

                  hasContent = packages ? ${b.name};
                }
            ) bundles
          );
        }) waves;
      };

      copyCommands = lib.concatStringsSep "\n" (
        lib.filter (s: s != "") (
          mapAttrsToList (
            key: pkg:
            let
              dir = dirOf key;
            in
            if dir == null then
              ""
            else
              ''
                mkdir -p "$out/${dir}"
                if [ -d "${pkg}" ]; then
                  cp -r --no-preserve=mode ${pkg}/* "$out/${dir}/" 2>/dev/null || true
                else
                  cp --no-preserve=mode ${pkg} "$out/${dir}/manifests.yaml"
                fi
              ''
          ) packages
        )
      );
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.yq-go ];
        waveMetaJson = builtins.toJSON waveMeta;
        passAsFile = [ "waveMetaJson" ];
      }
      ''
        mkdir -p $out
        ${copyCommands}

        find "$out" -name '*.yaml' -type f | while read -r f; do
          yq -P -i '.' "$f" 2>/dev/null || true
        done

        cp "$waveMetaJsonPath" "$out/.wave-meta"

        find "$out" -mindepth 2 -maxdepth 2 -type d | while read -r bdir; do
          crds="$(
            {
              find "$bdir" -name '*.yaml' -type f -exec \
                yq -rN '
                  select(.kind == "CustomResourceDefinition")
                  | .metadata.name
                  | select(. != null)
                ' {} \; \
                2>/dev/null | grep -v '^$' | sort -u
            } || true
          )"
          if [ -n "$crds" ]; then
            printf '%s\n' "$crds" > "$bdir/.crd-wait"
          fi
        done
      '';

}
