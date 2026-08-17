# Software Bill of Materials

Every lab package carries a `sbom.json`:

```
nix build .#labPackages."homelab.local"
jq '.components | group_by(.type) | map({(.[0].type): length}) | add' result/sbom.json
```

```json
{ "application": 20, "container": 41, "library": 19 }
```

It is [CycloneDX 1.6](https://cyclonedx.org/), so `grype`, `trivy` and
Dependency-Track read it without a converter:

```
grype sbom:result/sbom.json
```

## What is in it

Three kinds of component, and a dependency graph joining them.

| Kind  | `type`        | Comes from                        |
| ----- | ------------- | --------------------------------- |
| floe  | `application` | `floes.<name>` and its `version`  |
| chart | `library`     | the rendered chart's `Chart.yaml` |
| image | `container`   | the rendered manifests            |

Images are read out of the **rendered** manifests, not out of what floes
declare. That is the difference that matters: most images reach a cluster as
a chart's own default, never passing through `floes.<name>.images`, and a
bill of materials that lists only what was declared misses them. The
dependency graph attributes each one to the floe whose bundle rendered it:

```json
{
  "ref": "floe/gateway@v3.3.6",
  "dependsOn": [
    "helm/traefik@35.2.0",
    "image/docker.io/traefik:v3.3.6@sha256:83f3c8..."
  ]
}
```

`traefik:v3.3.6` is pinned inside the Traefik chart's values. Nothing in the
lab wrote that number down, and it is in the document anyway.

## Pinning is what makes it actionable

A `pkg:oci` purl identifies an artefact by digest. A tag cannot stand in:
`nginx:1.27` before and after a retag would look like the same thing, which
is the confusion an SBOM exists to remove. So an image this lab has no
digest for gets **no purl at all** — it still appears, with its name, its
tag and a `catallaxy:image:ref` property, but scanners that key on purls
will skip it.

Generating a lock is what turns that on:

```
cata images lock
```

With [`lab.images.lockFile`](./images.md) set, the same component becomes:

```json
{
  "bom-ref": "image/docker.io/traefik:v3.3.6@sha256:83f3c8...",
  "type": "container",
  "name": "docker.io/traefik",
  "version": "v3.3.6",
  "hashes": [{ "alg": "SHA-256", "content": "83f3c8..." }],
  "purl": "pkg:oci/traefik@sha256%3A83f3c8...?repository_url=docker.io/traefik&tag=v3.3.6"
}
```

The `:` in the digest is percent-encoded, as the purl spec requires.

## How it is built

The rendered manifest trees are the source, the same ones `images.txt` is
scraped from — and the build asserts the two agree, so the SBOM cannot
quietly describe less than the lab renders.

Attribution works by bundle directory. Each strategy renders a bundle into a
directory named after it (`NN-wave/<bundle>` under kapp, `bundles/<bundle>`
under Argo, `<bundle>/` under Fleet), and evaluation hands the build a table
mapping those directory names to floes.

An image in a bundle that names no floe would be recorded but owned by
nobody. A check asserts that set is empty for every layout, so in practice
each image has an owner. The stamp a bundle is attributed by comes from
`mkFloe`, and it reaches bundles a floe declares in an imported submodule as
well as those in its module body — the same stamp
`cluster.out.imageCompleteness` uses to decide which rendered bundles a
floe's `imagesComplete` claim covers.

## Deliberate omissions

**No `serialNumber` and no `metadata.timestamp`.** Both are optional in
CycloneDX and both would change on every build, making the derivation
irreproducible and turning `nix flake check` into a permanent diff. If you
need a serial number, add one when you publish, not when you build.

**Charts are always `pkg:helm`**, even the ones pulled over OCI
(`netbird-operator`, `forgejo`, `kaniop`). `Chart.yaml` does not record
where the chart came from, and one uniform documented answer beats a guess.

**Probe images are missing.** The images behind `lab.images.wait` land in
kapp's `.wave-meta`, which is JSON rather than YAML, so the manifest scrape
does not see them. `images.txt` has the same gap, and so therefore does
`cata images mirror`. Widening the SBOM alone would break the agreement
between the two that keeps both honest.

**No placement.** The document says what the lab is made of, not where any
of it runs. Two clusters running one version of a floe give one component;
at different versions, two. For what runs where, see `cata lab topology` and
`metadata.json`.
