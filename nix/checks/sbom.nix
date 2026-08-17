{
  lib,
  pkgs,
  mkLab,
}:

let
  transform = ../../lib/render/sbom/cyclonedx.jq;

  labWith =
    modules:
    (mkLab {
      modules = [
        {
          lab.name = "sbom-fixture";
          lab.environment = "development";
          lab.dns.enable = false;
          lab.registry.enable = false;
          lab.proxy.enable = false;
        }
      ]
      ++ modules;
    }).config.lab.out.package;

  base =
    { lab, ... }:
    {
      cluster.name = "app";
      cluster.provisioner = "k3d";
      provisioner.k3d.network = lab.name;

      floes.cert-manager.enable = true;
      floes.reloader.enable = true;
      floes.gateway.enable = true;
    };

  unpinned = labWith [ { lab.clusters.app = base; } ];

  pinned = labWith [
    {
      lab.clusters.app = base;
      lab.images.lockFile = ./sbom-fixture.lock.json;
    }
  ];

  withStrategy =
    strategy:
    labWith [
      {
        lab.cd.strategy = strategy;
        lab.clusters.app =
          { lab, ... }:
          {
            cluster.name = "app";
            cluster.provisioner = "k3d";
            provisioner.k3d.network = lab.name;

            floes.argocd.enable = strategy == "argocd";
            floes.cert-manager.enable = true;
            floes.reloader.enable = true;
            floes.gateway.enable = true;
          };
      }
    ];

  refCases = builtins.toJSON {
    lab.name = "units";
    floes = [ ];
    charts = [ ];
    imagePairs = [ ];
    unattributed = [
      "nginx:1.27"
      "docker.io/traefik:v3.3.6"
      "registry.internal:5000/ns/app:1.0"
      "ghcr.io/x/y:1.0@sha256:abc123"
      "ghcr.io/x/y@sha256:def456"
      "busybox"
      "ghcr.io/Org/MixedCase:2.0"
    ];
  };
in
{
  sbom-purls-are-what-the-spec-says =
    pkgs.runCommand "sbom-purls-are-what-the-spec-says"
      {
        nativeBuildInputs = [ pkgs.jq ];
        passAsFile = [ "cases" ];
        cases = refCases;
      }
      ''
        jq -f ${transform} "$casesPath" > doc.json

        want() {
          got=$(jq -r --arg r "image/$1" \
            '.components[] | select(.["bom-ref"] == $r) | [.name, (.version // ""), (.purl // "")] | @tsv' doc.json)
          if [ "$got" != "$(printf '%s\t%s\t%s' "$2" "$3" "$4")" ]; then
            echo "for $1" >&2
            echo "  want: $2 | $3 | $4" >&2
            echo "  got:  $got" >&2
            exit 1
          fi
        }

        want nginx:1.27 docker.io/nginx 1.27 ""
        want docker.io/traefik:v3.3.6 docker.io/traefik v3.3.6 ""
        want registry.internal:5000/ns/app:1.0 registry.internal:5000/ns/app 1.0 ""
        want busybox docker.io/busybox "" ""

        want ghcr.io/x/y:1.0@sha256:abc123 ghcr.io/x/y 1.0 \
          'pkg:oci/y@sha256%3Aabc123?repository_url=ghcr.io/x/y&tag=1.0'
        want ghcr.io/x/y@sha256:def456 ghcr.io/x/y sha256:def456 \
          'pkg:oci/y@sha256%3Adef456?repository_url=ghcr.io/x/y'
        want ghcr.io/Org/MixedCase:2.0 ghcr.io/Org/MixedCase 2.0 ""

        # A purl key that is present and null would satisfy `.purl // ""`
        # while still being wrong, so absence is asserted directly.
        for r in nginx:1.27 busybox registry.internal:5000/ns/app:1.0; do
          jq -e --arg r "image/$r" \
            '[.components[] | select(.["bom-ref"] == $r) | has("purl")] == [false]' doc.json > /dev/null || {
            echo "$r has a purl key, but nothing pinned it" >&2
            exit 1
          }
        done

        touch $out
      '';

  sbom-reference-parsing-is-lossless =
    pkgs.runCommand "sbom-reference-parsing-is-lossless"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq -R -s 'split("\n") | map(select(length > 0))
                  | { lab: { name: "roundtrip" }, floes: [], charts: [],
                      imagePairs: [], unattributed: . }' ${unpinned}/images.txt > in.json

        jq -f ${transform} in.json > doc.json

        # `name` is registry/repository and `version` is the tag, so the two
        # plus the digest have to spell the original again. A reference with
        # no registry gains the implicit one, which is the only rewriting the
        # parser is allowed to do.
        cat > roundtrip.jq <<'JQ'
        def rebuilt:
          (.properties[0].value | split("@")) as $parts
          | .name
            + (if .version == null or (.version | startswith("sha256:")) then ""
               else ":" + .version end)
            + (if ($parts | length) > 1 then "@" + $parts[1] else "" end);
        def want:
          .properties[0].value
          | if (split("/")[0] | test("[.:]")) then . else "docker.io/" + . end;
        [ .components[] | select(.type == "container")
          | { ref: .properties[0].value, rebuilt: rebuilt, want: want }
          | select(.rebuilt != .want) ]
        JQ

        jq -e -f roundtrip.jq doc.json | jq -e 'length == 0' > /dev/null || {
          echo "parsing lost or altered part of a reference:" >&2
          jq -f roundtrip.jq doc.json >&2
          exit 1
        }

        touch $out
      '';

  sbom-describes-the-rendered-lab =
    pkgs.runCommand "sbom-describes-the-rendered-lab"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        doc=${unpinned}/sbom.json

        jq -e '.bomFormat == "CycloneDX" and .specVersion == "1.6"' "$doc" > /dev/null || {
          echo "not a CycloneDX 1.6 document" >&2
          exit 1
        }

        # Both are optional, and either would make the derivation
        # irreproducible for no gain.
        jq -e 'has("serialNumber") | not' "$doc" > /dev/null || {
          echo "the document carries a serial number, which is not reproducible" >&2
          exit 1
        }
        jq -e '.metadata | has("timestamp") | not' "$doc" > /dev/null || {
          echo "the document carries a timestamp, which is not reproducible" >&2
          exit 1
        }

        jq -r '.components[] | select(.type == "container") | .properties[0].value' "$doc" \
          | sort -u > from-sbom.txt
        sort -u ${unpinned}/images.txt > from-images.txt
        if ! diff -u from-images.txt from-sbom.txt; then
          echo "" >&2
          echo "The SBOM and images.txt are scraped from the same trees, so" >&2
          echo "they cannot disagree about what the lab renders." >&2
          exit 1
        fi

        jq -e '[.components[] | select(.type == "library" and (.purl // "" | startswith("pkg:helm/")))] | length > 0' "$doc" > /dev/null || {
          echo "no chart was recorded, so the helm half checked nothing" >&2
          exit 1
        }

        # Every edge has to land on a component that exists, which is what
        # catches an image attributed to a bundle directory that is not the
        # one it was rendered into.
        jq -e '
          ([.components[].["bom-ref"]] + [.metadata.component.["bom-ref"]] | unique) as $known
          | [.dependencies[] | .dependsOn[] | select(($known | index(.)) | not)] == []
        ' "$doc" > /dev/null || {
          echo "a dependency names a component the document does not declare:" >&2
          jq -r '([.components[].["bom-ref"]] + [.metadata.component.["bom-ref"]] | unique) as $known
                 | .dependencies[] | .dependsOn[] | select(($known | index(.)) | not)' "$doc" >&2
          exit 1
        }

        # An image nothing owns is an attribution failure, not a fact about
        # the lab, so for a fixture this small it must be empty.
        jq -e '
          ([.dependencies[] | select(.ref | startswith("floe/")) | .dependsOn[]] | unique) as $owned
          | [.components[] | select(.type == "container")
             | select((.["bom-ref"] as $r | $owned | index($r)) | not) | .["bom-ref"]] == []
        ' "$doc" > /dev/null || {
          echo "these images were attributed to no floe:" >&2
          jq -r '([.dependencies[] | select(.ref | startswith("floe/")) | .dependsOn[]] | unique) as $owned
                 | .components[] | select(.type == "container")
                 | select((.["bom-ref"] as $r | $owned | index($r)) | not) | .["bom-ref"]' "$doc" >&2
          exit 1
        }

        touch $out
      '';

  # Each strategy renders a bundle into a differently shaped directory, and
  # attribution matches on the basename rather than the shape. kapp is
  # covered above; these are the other two.
  sbom-reaches-every-bundle-layout =
    pkgs.runCommand "sbom-reaches-every-bundle-layout"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        layout() {
          strategy="$1"
          doc="$2/sbom.json"

          jq -r '.components[] | select(.type == "container") | .properties[0].value' "$doc" \
            | sort -u > from-sbom.txt
          sort -u "$2/images.txt" > from-images.txt
          if ! diff -u from-images.txt from-sbom.txt; then
            echo "" >&2
            echo "Under the $strategy layout the SBOM and images.txt disagree." >&2
            exit 1
          fi

          jq -e '
            ([.components[].["bom-ref"]] + [.metadata.component.["bom-ref"]] | unique) as $known
            | [.dependencies[] | .dependsOn[] | select(($known | index(.)) | not)] == []
          ' "$doc" > /dev/null || {
            echo "under $strategy a dependency names a component that is not declared" >&2
            exit 1
          }

          jq -e '
            ([.dependencies[] | select(.ref | startswith("floe/")) | .dependsOn[]] | unique) as $owned
            | [.components[] | select(.type == "container")
               | select((.["bom-ref"] as $r | $owned | index($r)) | not) | .["bom-ref"]] == []
          ' "$doc" > /dev/null || {
            echo "under $strategy these images were attributed to no floe:" >&2
            jq -r '([.dependencies[] | select(.ref | startswith("floe/")) | .dependsOn[]] | unique) as $owned
                   | .components[] | select(.type == "container")
                   | select((.["bom-ref"] as $r | $owned | index($r)) | not) | .["bom-ref"]' "$doc" >&2
            exit 1
          }

          owned=$(jq -r '[.dependencies[] | select(.ref | startswith("floe/")) | .dependsOn[]
                         | select(startswith("image/"))] | unique | length' "$doc")
          if [ "$owned" = 0 ]; then
            echo "under $strategy no image was attributed, so the layout never matched" >&2
            exit 1
          fi
        }

        layout argocd ${withStrategy "argocd"}
        layout fleet ${withStrategy "fleet"}

        touch $out
      '';

  sbom-carries-purls-for-what-the-lock-pins =
    pkgs.runCommand "sbom-carries-purls-for-what-the-lock-pins"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        doc=${pinned}/sbom.json

        pinnedCount=$(jq -r '.images | length' ${./sbom-fixture.lock.json})
        withPurl=$(jq -r '[.components[] | select(.type == "container" and (.purl // "" | startswith("pkg:oci/")))] | length' "$doc")

        if [ "$withPurl" = 0 ]; then
          echo "the lock pins $pinnedCount images and none reached a purl" >&2
          jq -r '.components[] | select(.type == "container") | .["bom-ref"]' "$doc" >&2
          exit 1
        fi

        # The digest in the purl and the hash beside it have to be the digest
        # the lock names, or the document points at a different artefact.
        jq -e --slurpfile lock ${./sbom-fixture.lock.json} '
          ($lock[0].images | to_entries | map({ key: .key, digest: .value })) as $want
          | [ .components[] | select(.type == "container" and (.purl // "" | startswith("pkg:oci/")))
              | { ref: .properties[0].value, hash: .hashes[0].content, purl: .purl } ]
            | all(
                .hash as $h | .purl as $p | .ref as $r
                | ($want | any(.key as $k | .digest as $d
                               | $d == ("sha256:" + $h) and ($r | startswith($k))))
                  and ($p | contains("sha256%3A" + $h))
              )
        ' "$doc" > /dev/null || {
          echo "a pinned component does not carry the digest the lock names" >&2
          jq -r '.components[] | select(.type == "container" and (.purl // "" | startswith("pkg:oci/")))
                 | [.properties[0].value, .hashes[0].content, .purl] | @tsv' "$doc" >&2
          exit 1
        }

        touch $out
      '';
}
