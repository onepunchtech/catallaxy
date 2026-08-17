{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;

  imageUtil = import ../../../lib/render/images.nix { inherit lib pkgs; };
  sbomLib = import ../../../lib/render/sbom.nix { inherit lib; };

  clusters = lib.mapAttrsToList (name: clusterCfg: {
    tree = "${config.lab.out.manifests.${name}}/${name}";
    view = config.lab.out.manifestViews.${name};
    inherit (clusterCfg) floes;
  }) config.lab.out.allClusters;

  collisions = sbomLib.collisionsOf clusters;

  input = sbomLib.evalInput {
    labName = config.lab.name;
    inherit clusters;
  };

  scrapeInto = quotedDir: label: sink: ''
    for f in $(find -L ${quotedDir} -name '*.yaml' -type f 2>/dev/null); do
      yq -N '${imageUtil.scrapeExpr}' "$f" 2>/dev/null \
        | grep -v '^$' | grep -v '^null$' \
        | sed "s|^|${label}|" >> ${sink} || true
    done
  '';

  perBundle = lib.concatMapStringsSep "\n" (
    cluster:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (dir: floeRef: ''
        while read -r d; do
          [ -n "$d" ] || continue
          ${scrapeInto "\"$d\"" "${toString floeRef}\t" "pairs.tsv"}
        done < <(find -L ${lib.escapeShellArg cluster.tree} -type d -name ${lib.escapeShellArg dir} 2>/dev/null)
      '') cluster.bundles
    )
  ) input.clusters;

  wholeTree = lib.concatMapStringsSep "\n" (
    cluster: scrapeInto (lib.escapeShellArg cluster.tree) "" "all-images.txt"
  ) input.clusters;

  chartReads = lib.concatMapStringsSep "\n" (
    cluster:
    lib.concatMapStringsSep "\n" (chart: ''
      readChart ${lib.escapeShellArg chart.path} ${lib.escapeShellArg chart.key} ${lib.escapeShellArg (toString chart.floeRef)}
    '') cluster.charts
  ) input.clusters;

  document =
    pkgs.runCommand "sbom-${config.lab.name}.json"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.yq-go
        ];
        passAsFile = [ "evalInput" ];
        evalInput = builtins.toJSON input;
      }
      ''
        : > pairs.tsv
        : > all-images.txt
        : > charts.jsonl

        readChart() {
          chartPath="$1"
          chartKey="$2"
          chartFloe="$3"
          name=""
          version=""
          if [ -f "$chartPath/Chart.yaml" ]; then
            name=$(yq -N '.name // ""' "$chartPath/Chart.yaml" 2>/dev/null || true)
            version=$(yq -N '.version // ""' "$chartPath/Chart.yaml" 2>/dev/null || true)
          elif [ -f "$chartPath" ]; then
            meta=$(tar -xzOf "$chartPath" --wildcards '*/Chart.yaml' 2>/dev/null || true)
            if [ -n "$meta" ]; then
              name=$(printf '%s' "$meta" | yq -N '.name // ""' 2>/dev/null || true)
              version=$(printf '%s' "$meta" | yq -N '.version // ""' 2>/dev/null || true)
            fi
          fi
          [ -n "$name" ] || name="$chartKey"
          jq -nc --arg n "$name" --arg v "$version" --arg f "$chartFloe" \
            '{ name: $n, version: (if $v == "" then null else $v end),
               floeRef: (if $f == "" then null else $f end) }' >> charts.jsonl
        }

        ${perBundle}
        ${wholeTree}
        ${chartReads}

        sort -u all-images.txt > all.txt
        cut -f2 pairs.tsv | sort -u > attributed.txt

        comm -23 attributed.txt all.txt > extra.txt
        if [ -s extra.txt ]; then
          echo "the per-bundle scrape found images the whole-tree scrape did not:" >&2
          cat extra.txt >&2
          echo "" >&2
          echo "A bundle directory matched something outside the cluster tree," >&2
          echo "or matched twice, so the SBOM would describe images the lab" >&2
          echo "does not render." >&2
          exit 1
        fi

        comm -13 attributed.txt all.txt > unattributed.txt

        jq -s '.' charts.jsonl > charts.json
        jq -R 'split("\t") | { floeRef: (if .[0] == "" then null else .[0] end), ref: .[1] }' \
          pairs.tsv | jq -s 'unique' > pairs.json
        jq -R . unattributed.txt | jq -s '.' > unattributed.json

        jq --slurpfile pairs pairs.json \
           --slurpfile charts charts.json \
           --slurpfile unattributed unattributed.json \
           '. + { imagePairs: $pairs[0], charts: ($charts[0] | unique), unattributed: $unattributed[0] }' \
           "$evalInputPath" > input.json

        jq -f ${../../../lib/render/sbom/cyclonedx.jq} input.json > $out
      '';
in
{
  options.lab.out.sbom = mkOption {
    type = types.package;
    readOnly = true;
    internal = true;
    description = ''
      A CycloneDX 1.6 document describing what the lab is made of.

      Built from the rendered manifests rather than from what floes
      declare, so an image a chart pins in its own values is counted like
      any other. Every image is attributed to the floe whose bundle
      rendered it, and the union of attributed and unattributed images is
      checked against the same trees `images.txt` is scraped from.

      Carries no timestamp and no serial number: both are optional in
      CycloneDX and either would make the derivation irreproducible.
    '';
  };

  config = {
    assertions = lib.optional (collisions != [ ]) {
      assertion = false;
      message = ''
        A bundle name collides with a directory the rendered layout uses
        for structure: ${lib.concatStringsSep ", " collisions}.

        The SBOM attributes an image to a floe by the bundle directory it
        was rendered into, so a bundle called ${lib.concatStringsSep " or " sbomLib.structuralDirs} would claim files that belong to the layout rather than to it.
      '';
    };

    lab.out.sbom = document;
  };
}
