# Images and Registries

Pinning images so a deploy is reproducible, getting them onto a machine that
may not have internet, and publishing images the lab builds itself.

## Policy

```nix
lab.images.requireDigest = true;
lab.images.allowedRegistries = [ "ghcr.io" "registry.k8s.io" "docker.io" ];
```

Both ([`requireDigest`](./options/lab.md#images-requiredigest),
[`allowedRegistries`](./options/lab.md#images-allowedregistries)) are
enforced by the `image-pin` [lint rule](./lint.md), not at apply time, you
find out in CI, not during a rollout.

`requireDigest` errors on any image without a `sha256:` digest.
`allowedRegistries`, when non-empty, warns about images from anywhere else.
Leave both off while iterating. Turn them on before anything matters.

Per-resource exemption where a rule is genuinely wrong:

```yaml
metadata:
  annotations:
    catallaxy.io/lint-skip: image-pin
```

## The lockfile

`requireDigest` is only satisfiable if something puts digests into the
rendered manifests, because most images arrive from a Helm chart and no
option can reach inside one.

```
cata images lock --name mylab.local
```

resolves every image the lab renders and writes `images.lock.json`. Point
the lab at it, commit both:

```nix
lab.images.lockFile = ./images.lock.json;
lab.images.requireDigest = true;
```

Every reference the file names is rewritten to carry its digest as the
manifests are rendered. A reference that already has one is left alone, and
a string the file does not name is left alone, so the lockfile is its own
filter.

Leaving `lockFile` null rewrites nothing. That is what lets a lab build
before a lockfile exists, which is how you generate the first one.

Bumping a chart means re-running the command. If you forget, `image-pin`
names the image that moved.

### What it does not cover

The scrape that finds images to lock reads the same container paths the
`image-pin` lint reads: containers and init containers on a Pod, on a pod
template, and inside a CronJob's job template. An operator CR carrying its
own `spec.image` is invisible to both, so `requireDigest` passing says less
than it looks on an operator-heavy lab.

Retargeting does not share that blind spot: it descends rather than reading
a path list, so it reaches a CR's own image. Declaring reaches it too,
because `imagesComplete` scrapes what was rendered rather than what a list
expected.

## Declared images

A floe names the images it needs, keyed by a label that is part of its
interface:

```nix
floes.openbao.images.server = {
  registry = "quay.io";
  repository = "openbao/openbao";
  tag = "2.3.1";
};
```

The floe reads `cfg.images.server.ref` rather than writing the string, and
where the chart takes registry and repository as separate values, the
declaration sets them. Declaring is the floe saying this combination was
tested, and it is what gives you something to override.

A floe that has declared everything it renders sets `imagesComplete = true`.
The `image-sets-are-complete` check then renders that floe and fails naming
any image it did not declare, so the claim cannot quietly go stale.

## Retargeting

One line points a whole lab at a mirror or an internal registry:

```nix
lab.images.registry = "registry.internal";
```

Repositories and tags are untouched, so the target has to carry the same
paths upstream does. A pull-through cache does.

This reaches every image a lab renders, not only the declared ones, because
until every chart image is declared most of what a lab renders is a chart's
own choice. Two things are left alone: anything inside a ConfigMap or a
Secret, where an `image` key is somebody's config rather than a workload,
and any value that carries neither a path nor a tag and so is not a
reference anyone could pull.

Individual images are overridden by label:

```nix
lab.images.pinned.openbao.server = {
  registry = "registry.internal";
  digest = "sha256:abc123…";
};
```

Matching is by label and nothing else, so you name the image you mean rather
than catallaxy inferring from a repository two floes might share. Any field
left unset keeps what the floe declared, and a pin beats
`lab.images.registry`, which is what lets a lab mirror everything and still
take one image from somewhere else.

## Local registry

```nix
lab.registry.enable = true;
```

Runs a [Zot](https://zotregistry.dev/) pull-through cache as a host service.
The plan writes `registries.yaml` and `certs.d` into each cluster so pulls
route through it transparently.

Worth it for two reasons: `lab destroy` followed by `lab up` does not
re-download several gigabytes, and a lab keeps working on a bad connection.

```bash
cata --flake .#<lab> images list                 # everything the lab references
cata --flake .#<lab> images prefetch             # pull it all into the cache
cata --flake .#<lab> images prefetch --dry-run
```

`images list` reads `images.txt` from the rendered package, which is
extracted from every pod template at build time, so it covers init
containers and CronJob templates too, not just the obvious ones.

## What is actually running

```bash
cata --flake .#<lab> images actual
cata --flake .#<lab> images actual --undeclared
cata --flake .#<lab> images actual --cluster obs
```

`list` says what catallaxy rendered. It cannot say what arrived: an operator
creates workloads catallaxy never wrote, so a CNPG Postgres pod or a
StatefulSet an operator built are invisible to anything reading manifests,
however many paths it reads. This asks the clusters instead.

`--undeclared` narrows it to what the lab never rendered, which is exactly
the set an operator created. That is the list to hand to a mirror before an
air-gapped or edge deployment, because it is the part nothing else finds.

It reports what has already run, so a workload that has not started yet is
not in it. That makes this a discovery aid rather than an authority: the
declared set is what a lab is built from, and this is how you find out what
the declared set is missing.

## Mirroring

```bash
cata --flake .#<lab> images mirror --registry registry.example.com/lab
```

Copies every image the lab references into a registry you control, using
`crane`. For air-gapped installs, or for not depending on Docker Hub rate
limits in CI.

## Publishing images the lab builds

`lab.images.publish.<name>` declares an image built from a flake input and
pushed to a registry as part of the deploy plan:

```nix
lab.images.publish.my-api = {
  source = inputs.my-api;
  attr = "packages.x86_64-linux.container";
  tagFrom = "Cargo.toml";
  destination = {
    registry = "harbor.lab.test";
    repository = "apps/my-api";
  };
  credentialsRef = {
    cluster = "mgmt";
    namespace = "harbor";
    secretName = "harbor-robot";
  };
};
```

| Field                               | Meaning                                                                                   |
| ----------------------------------- | ----------------------------------------------------------------------------------------- |
| `source`                            | flake input holding the image derivation                                                  |
| `attr`                              | attribute path to it                                                                      |
| `tag` / `tagFrom`                   | explicit tag, or read one from a versioned file (`Cargo.toml`, `package.json`, `VERSION`) |
| `alsoLatest`                        | additionally push `:latest`                                                               |
| `destination.{registry,repository}` | where it goes                                                                             |
| `credentialsRef`                    | a Secret in a lab cluster holding the push credentials                                    |

`tagFrom` is the useful one: the version in the app's own manifest becomes
the image tag, so the app has a single source of truth and the lab follows
it.

The planner emits a `publish-images` step per source cluster, ordered after
that cluster's manifests and before any consuming cluster's: the image
exists before anything tries to pull it. Consumers read
`lab.images.publish.<name>.ref` for the full reference.
