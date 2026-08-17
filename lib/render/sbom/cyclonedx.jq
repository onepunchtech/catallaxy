# Assemble a CycloneDX 1.6 document from the eval-time description of a lab
# joined with what was scraped out of its rendered manifests.
#
# Input on stdin:
#   { lab: { name }, floes: [ { ref, name, version } ],
#     imagePairs: [ { floeRef, ref } ], unattributed: [ ref ],
#     charts: [ { floeRef, name, version } ] }

# Split a reference the way cli/src/images/reference.rs ImageRef::parse does.
# Digest first, because splitting on `@` alone leaves the tag stuck to the
# repository. Then a colon after the last slash is a tag and one before it is
# a registry port. Then a first segment carrying a dot or a colon is a
# hostname, and anything else means the registry is implicit.
def parse_ref:
  . as $image
  | (if ($image | test("@")) then ($image | split("@")) else [$image] end) as $parts
  | $parts[0] as $before_digest
  | (if ($parts | length) > 1 then $parts[1] else null end) as $digest
  | ($before_digest | (rindex(":") // -1)) as $colon
  | (if $colon >= 0 and (($before_digest[$colon + 1:] | test("/")) | not)
     then { repo_part: $before_digest[:$colon], tag: $before_digest[$colon + 1:] }
     else { repo_part: $before_digest, tag: null }
     end) as $t
  | ($t.repo_part | (index("/") // -1)) as $slash
  | (if $slash >= 0
       and (($t.repo_part[:$slash] | test("[.:]")))
     then { registry: $t.repo_part[:$slash], repository: $t.repo_part[$slash + 1:] }
     else { registry: "docker.io", repository: $t.repo_part }
     end) as $r
  | { registry: $r.registry, repository: $r.repository, tag: $t.tag, digest: $digest };

# pkg:oci requires the version to be the digest. A tag in that slot is not a
# valid OCI purl, and it would make the same reference before and after a
# retag look like one artefact, which is the thing an SBOM exists to prevent.
# So an unpinned image gets no purl at all.
def oci_purl($p):
  if $p.digest == null then null
  else
    "pkg:oci/"
    + ($p.repository | split("/") | last | ascii_downcase)
    + "@" + ($p.digest | sub(":"; "%3A"))
    + "?repository_url=" + $p.registry + "/" + $p.repository
    + (if $p.tag == null then "" else "&tag=" + $p.tag end)
  end;

def image_component($ref):
  ($ref | parse_ref) as $p
  | { "bom-ref": ("image/" + $ref),
      type: "container",
      name: ($p.registry + "/" + $p.repository),
      properties: [ { name: "catallaxy:image:ref", value: $ref } ] }
  + (if $p.tag != null then { version: $p.tag }
     elif $p.digest != null then { version: $p.digest }
     else {} end)
  + (if $p.digest != null and ($p.digest | startswith("sha256:"))
     then { hashes: [ { alg: "SHA-256", content: ($p.digest | ltrimstr("sha256:")) } ] }
     else {} end)
  + (oci_purl($p) as $purl | if $purl == null then {} else { purl: $purl } end);

def chart_ref: "helm/" + .name + (if .version == null then "" else "@" + .version end);

# pkg:helm even for charts pulled over OCI: Chart.yaml cannot tell you the
# origin, and guessing is worse than one uniform, documented answer.
def chart_component:
  { "bom-ref": chart_ref, type: "library", name: .name }
  + (if .version == null then {}
     else { version: .version, purl: ("pkg:helm/" + .name + "@" + .version) }
     end);

def floe_component:
  { "bom-ref": .ref, type: "application", name: .name }
  + (if .version == null then {} else { version: .version } end);

def assemble:
  . as $in
  | ($in.lab.name) as $labName
  | ("lab/" + $labName) as $labRef
  | ([ $in.imagePairs[].ref ] + $in.unattributed | unique) as $images
  | ([ $in.charts[] | { name, version } ] | unique) as $charts
  | ([ $in.imagePairs[] | select(.floeRef != null)
       | { floe: .floeRef, dep: ("image/" + .ref) } ]
     + [ $in.charts[] | select(.floeRef != null)
       | { floe: .floeRef, dep: (. | chart_ref) } ]) as $edges
  | ([ $images[] | image_component(.) ]
     + [ $charts[] | chart_component ]
     + [ $in.floes[] | floe_component ]) as $components
  | { bomFormat: "CycloneDX",
      specVersion: "1.6",
      version: 1,
      metadata: {
        component: { "bom-ref": $labRef, type: "application", name: $labName },
        tools: { components: [ { type: "application", name: "catallaxy" } ] }
      },
      components: ($components | sort_by(.["bom-ref"])),
      dependencies: (
        [ { ref: $labRef, dependsOn: ([ $in.floes[].ref ] | unique) } ]
        + ([ $edges[] ] | group_by(.floe)
           | map({ ref: .[0].floe, dependsOn: ([ .[].dep ] | unique) }))
        + ([ $components[].["bom-ref"] ] - ([ $edges[].floe ] | unique)
           | map(select(. != $labRef) | { ref: ., dependsOn: [] }))
        | group_by(.ref) | map({ ref: .[0].ref, dependsOn: ([ .[].dependsOn[] ] | unique) })
        | sort_by(.ref)
      ) };

assemble
