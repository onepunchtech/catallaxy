{
  lib,
  pkgs,
  labs,
}:

let
  manifestsOf =
    labName: labDef:
    lib.mapAttrsToList (clusterName: _: {
      name = "${labName}-${clusterName}";
      manifests = labDef.config.lab.out.manifests.${clusterName};
      lab = labName;
    }) labDef.config.lab.clusters;

  targets = lib.concatLists (lib.mapAttrsToList manifestsOf labs);

  checkOne = target: {
    name = "every-rendered-resource-says-who-owns-it-${target.name}";
    value =
      pkgs.runCommand "every-rendered-resource-says-who-owns-it-${target.name}"
        {
          nativeBuildInputs = [ pkgs.yq-go ];
        }
        ''
          unlabelled=""
          total=0
          while IFS= read -r -d "" f; do
            found=$(yq 'select(.kind != null)
                        | select(.metadata.labels."catallaxy.io/lab" == null)
                        | [.kind, (.metadata.name // "<unnamed>")] | join("/")' "$f" 2>/dev/null \
                    | grep -v '^$' || true)
            counted=$(yq 'select(.kind != null) | .kind' "$f" 2>/dev/null | grep -c . || true)
            total=$((total + counted))
            if [ -n "$found" ]; then
              unlabelled="$unlabelled$f:"$'\n'
              unlabelled="$unlabelled$(printf '  %s\n' $found)"$'\n'
            fi
          done < <(find ${target.manifests} -name '*.yaml' -type f -print0)

          if [ -n "$unlabelled" ]; then
            echo "These rendered resources do not say which lab owns them:" >&2
            printf '%s' "$unlabelled" >&2
            echo >&2
            echo "\`lab up\` asks the cluster for resources carrying" >&2
            echo "catallaxy.io/lab and deletes the ones the declaration no" >&2
            echo "longer names. A resource without it is never a candidate," >&2
            echo "so disabling the floe that created it leaves it running" >&2
            echo "while \`lab up\` reports success." >&2
            echo >&2
            echo "Every bundle is stamped in lib/render/manifest.nix," >&2
            echo "whoever produced the YAML." >&2
            exit 1
          fi

          if [ "$total" -eq 0 ]; then
            echo "No resources were examined, so this check proved nothing." >&2
            exit 1
          fi

          echo "$total resources all say which lab and bundle own them" > "$out"
        '';
  };
in
lib.listToAttrs (map checkOne targets)
