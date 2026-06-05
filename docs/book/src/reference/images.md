# Image Management

Catallaxy provides declarative control over container images for reproducibility and security.

## Image Pins

Pin container images at the lab level with optional digest verification:

```nix
lab.images.pins = {
  grafana = {
    image = "docker.io/grafana/grafana";
    tag = "11.4.0";
    digest = "sha256:abc123...";  # Optional — ensures bit-for-bit reproducibility
  };
  prometheus = {
    image = "quay.io/prometheus/prometheus";
    tag = "v3.0.0";
  };
};
```

Each pin computes a `ref` — the full image reference string:

| Configuration | `ref` value |
|---------------|-------------|
| tag only | `docker.io/grafana/grafana:11.4.0` |
| digest only | `docker.io/grafana/grafana@sha256:abc123` |
| tag + digest | `docker.io/grafana/grafana:11.4.0@sha256:abc123` |

Components can reference pins: `lab.images.pins.grafana.ref`

## Image Policy

### Require Digest

When enabled, the lint check **errors** on any container image without a digest pin:

```nix
lab.images.requireDigest = true;
```

This enforces that every image in your rendered manifests is pinned to a specific build. Tags are mutable (a registry can serve a different image for the same tag), but digests are immutable.

### Allowed Registries

Restrict which registries images can come from:

```nix
lab.images.allowedRegistries = [
  "ghcr.io"
  "registry.k8s.io"
  "docker.io"
];
```

The lint check **warns** about images from registries not in this list. Leave empty (default) to allow all registries.

## Lint Check

The `image-pin` lint check scans rendered manifests for container image references in Deployments, StatefulSets, DaemonSets, Jobs, and CronJobs.

It always warns about:
- **`:latest` tags** — mutable and non-reproducible

With policy enabled:
- **Missing digests** (when `requireDigest = true`) — Error
- **Unapproved registries** (when `allowedRegistries` is set) — Warning

### Suppression

Skip the check for specific resources:

```yaml
metadata:
  annotations:
    catallaxy.io/lint-skip: image-pin
```

## Pull-Through Cache

For rate limiting protection, use Zot as a pull-through cache:

```nix
components.zot = {
  enable = true;
  sync.enable = true;  # Pull-through cache from Docker Hub, Quay, GHCR, registry.k8s.io
};
```

This caches images locally on first pull. Combined with image pins, you get both availability and reproducibility.
