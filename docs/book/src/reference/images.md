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

## Pins

```nix
lab.images.pins.grafana = {
  image = "docker.io/grafana/grafana";
  tag = "11.4.0";
  digest = "sha256:abc123…";
};
```

[`lab.images.pins.<name>.ref`](./options/lab.md#images-pins-name-ref) is the
assembled reference; use that rather than reconstructing the string:

```nix
floes.grafana.overrides.extraAnnotations."image" =
  lab.images.pins.grafana.ref;
```

One place to bump a version, and the digest travels with it.

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
