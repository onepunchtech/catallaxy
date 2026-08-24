{
  lib,
  pkgs,
  labs,
  schemas,
}:

let
  baseline = ./kubeconform-skipped-baseline.txt;

  clustersOf =
    labName: labDef:
    lib.mapAttrsToList (clusterName: cluster: {
      name = "${labName}-${clusterName}";
      manifests = labDef.config.lab.out.manifests.${clusterName};
      schemaDir = schemas.${cluster.cluster.kubernetes.version};
    }) labDef.config.lab.clusters;

  targets = lib.concatLists (lib.mapAttrsToList clustersOf labs);

  # kubeconform reads `-strict` off the path template, not off the schema, so
  # the two trees are two directories and the flag picks between them.
  location = dir: "${dir}/schemas{{ .StrictSuffix }}/{{ .ResourceKind }}{{ .KindSuffix }}.json";

  checkOne = target: {
    name = "manifests-match-their-schemas-${target.name}";
    value =
      pkgs.runCommand "manifests-match-their-schemas-${target.name}"
        {
          nativeBuildInputs = [
            pkgs.kubeconform
            pkgs.jq
          ];
        }
        ''
          # No default schema location: that one is a URL, and reaching for it
          # turns a missing schema into a sandbox network failure that reads
          # like a schema bug.
          # -verbose because without it the JSON lists only resources that
          # failed. A resource validated against no schema at all is reported
          # exactly like one that passed, which is the state this check exists
          # to make visible.
          run() {
            kubeconform \
              -n "$NIX_BUILD_CORES" \
              -verbose \
              -schema-location '${location target.schemaDir}' \
              -output json \
              -ignore-missing-schemas \
              "$@"
          }

          authored=$(find ${target.manifests} -name resources.yaml | sort)
          other=$(find ${target.manifests} -name '*.yaml' ! -name resources.yaml | sort)

          status=0
          if [ -n "$authored" ]; then
            # shellcheck disable=SC2086
            run -strict $authored > authored.json 2>&1 || status=$?
          else
            echo '{"resources":[]}' > authored.json
          fi

          if [ -n "$other" ]; then
            # shellcheck disable=SC2086
            run $other > other.json 2>&1 || status=$?
          else
            echo '{"resources":[]}' > other.json
          fi

          jq -s '[.[].resources[]] | map(select(.status == "statusInvalid" or .status == "statusError"))' \
            authored.json other.json > invalid.json

          jq -rs '[.[].resources[] | select(.status == "statusSkipped")
                   | "\(.version)/\(.kind)"] | unique | .[]' \
            authored.json other.json > skipped.txt

          validated=$(jq -s '[.[].resources[] | select(.status == "statusValid")] | length' \
            authored.json other.json)

          if [ "$validated" -eq 0 ]; then
            echo "Nothing was validated, so this check proved nothing." >&2
            echo "Either the manifest tree moved and the find patterns no longer" >&2
            echo "match it, or every resource was skipped for want of a schema." >&2
            exit 1
          fi

          if [ "$(jq 'length' invalid.json)" -ne 0 ]; then
            echo "These manifests do not match the schema their apiVersion names:" >&2
            jq -r '.[] | "  \(.filename): \(.kind) \(.name // ""): \(.msg)"' invalid.json >&2
            echo >&2
            echo "Resources this repo authors are checked strictly, so a field" >&2
            echo "Kubernetes does not declare is an error: that is a misspelled" >&2
            echo "key, which the Nix type layer passes through by design." >&2
            echo "Helm and upstream YAML are checked loosely, so a failure there" >&2
            echo "is a real mismatch against the pinned API version." >&2
            exit 1
          fi

          # Subset here, exact match in the union check below. One lab cannot
          # see the whole baseline, so asking each to match it exactly would
          # make every lab fail for gaps that are not its own.
          known=$(grep -vE '^\s*(#|$)' ${baseline} | sort)
          if ! new=$(comm -23 skipped.txt <(printf '%s\n' "$known")) || [ -n "$new" ]; then
            echo "These kinds are being applied with nothing checking them:" >&2
            printf '  %s\n' $new >&2
            echo >&2
            echo "Ship the schema by adding a \`crd\` definition in" >&2
            echo "lib/charts.nix and running \`nix run .#generate-k8s-types\`," >&2
            echo "or add the line to nix/checks/kubeconform-skipped-baseline.txt" >&2
            echo "to say the gap is known and deliberate." >&2
            exit 1
          fi

          if [ "$status" -ne 0 ]; then
            echo "kubeconform exited $status without reporting an invalid resource" >&2
            cat authored.json other.json >&2
            exit 1
          fi

          mkdir -p "$out"
          cp skipped.txt "$out/skipped.txt"
          echo "$validated" > "$out/validated"
        '';
  };

  perLab = lib.listToAttrs (map checkOne targets);
  # The rendered labs are all valid, so on their own they cannot tell a check
  # that works from one that validates nothing. These four say what each pass
  # is for: strict catches a key Kubernetes does not declare, which is the
  # misspelling the Nix type layer waves through; loose still catches a field
  # of the wrong type; and the split is real, so the same misspelling in helm
  # output is left alone rather than failing on a chart nobody here owns.
  fixtures = pkgs.runCommand "kubeconform-fixtures" { } ''
    mkdir -p "$out/authored" "$out/helm"

    cat > "$out/authored/resources.yaml" <<'YAML'
    apiVersion: v1
    kind: Service
    metadata:
      name: good
    spec:
      ports:
        - port: 80
    YAML

    cat > "$out/authored/misspelled.yaml" <<'YAML'
    apiVersion: v1
    kind: Service
    metadata:
      name: typo
    spec:
      portz:
        - port: 80
    YAML

    cat > "$out/authored/wrong-type.yaml" <<'YAML'
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: wrong
    spec:
      replicas: "three"
    YAML

    cat > "$out/helm/chart.yaml" <<'YAML'
    apiVersion: v1
    kind: Service
    metadata:
      name: from-a-chart
    spec:
      portz:
        - port: 80
    YAML
  '';

  anyVersion = lib.head (lib.attrValues schemas);
in
perLab
// {
  # The per-lab checks only refuse a *new* gap. This one refuses a stale
  # baseline entry, so a line cannot outlive the gap it documents and the set
  # can only shrink.
  every-unchecked-kind-is-one-we-know-about =
    pkgs.runCommand "every-unchecked-kind-is-one-we-know-about" { }
      ''
        cat ${lib.concatStringsSep " " (map (d: "${d}/skipped.txt") (lib.attrValues perLab))} \
          | sort -u > actual.txt

        known=$(grep -vE '^\s*(#|$)' ${baseline} | sort)
        if ! stale=$(comm -13 actual.txt <(printf '%s\n' "$known")) || [ -n "$stale" ]; then
          echo "These lines in nix/checks/kubeconform-skipped-baseline.txt no" >&2
          echo "longer describe anything, so the file overstates the gap:" >&2
          printf '  %s\n' $stale >&2
          echo >&2
          echo "Remove them. The baseline exists to shrink." >&2
          exit 1
        fi

        echo "$(wc -l < actual.txt) kinds are applied unchecked, all of them known" > "$out"
      '';
}
// {
  kubeconform-rejects-what-it-should =
    pkgs.runCommand "kubeconform-rejects-what-it-should"
      {
        nativeBuildInputs = [ pkgs.kubeconform ];
      }
      ''
        verdict() {
          local mode="$1" file="$2"
          local flag=""
          [ "$mode" = strict ] && flag=-strict
          if kubeconform $flag \
               -schema-location '${location anyVersion}' \
               -ignore-missing-schemas \
               "${fixtures}/$file" > /dev/null 2>&1; then
            echo accepted
          else
            echo rejected
          fi
        }

        fail=""
        expect() {
          local want="$1" mode="$2" file="$3" why="$4"
          local got
          got=$(verdict "$mode" "$file")
          if [ "$got" != "$want" ]; then
            fail="$fail\n  $mode $file: wanted $want, got $got ($why)"
          fi
        }

        expect accepted strict authored/resources.yaml "a well-formed Service"
        expect rejected strict authored/misspelled.yaml "spec.portz is not a field of a Service"
        expect rejected loose authored/wrong-type.yaml "replicas is an integer"
        expect accepted loose helm/chart.yaml "helm output is not checked for unknown keys"

        if [ -n "$fail" ]; then
          echo "kubeconform is not distinguishing what this check relies on it to:" >&2
          printf "%b\n" "$fail" >&2
          exit 1
        fi
        echo "strict rejects unknown keys, loose still rejects wrong types" > "$out"
      '';
}
