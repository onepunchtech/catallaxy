# Nix Helpers

Two sources. `k8sHelpers` and `cataCharts` arrive as module arguments inside
a floe. Everything under `catallaxy.lib` is the flake's public API,
importable from a consumer flake.

## `k8sHelpers` (resource constructors)

From `lib/k8s-helpers.nix`. These exist so floes stop hand-writing Gateway
API and cert-manager shapes, and so a shape change lands in one place.

### `mkGatewayExposure`

```nix
mkGatewayExposure {
  name, namespace, domain,
  gateway,                     # the floe's own `gateway` option block
  internalGatewayName,         # floes.gateway.exports.internalGatewayName
  sectionName,                 # floes.gateway.exports.terminatingListenerName
  backend,                     # { name; port; }
  pathPrefix ? "/",
  routeName ? "<name>-route",  # key in `resources`
  tls ? null,                  # { secretName; issuerRef; }
  labels ? { },
} -> resources
```

A floe's whole public face: the HTTPRoute that attaches it to a Gateway and
the Certificate that terminates TLS for it, guarded and ready to merge into
`bundles.<n>.resources`. Reach for this first; the pieces below are what it
is made of.

Empty when `gateway.enable` is false or `domain` is `""`. The certificate is
_not_ gated on `gateway.enable`, because a floe reached some other way still
wants one.

`sectionName` has no default on purpose. Eight floes built this by hand and
the copies disagreed about exactly this field: a lab with
`floes.gateway.tls.enable = false` exports `"http"`, and the ones that
assumed `"https"` named a listener that was not there.

### `mkGatewayParentFor`

```nix
mkGatewayParentFor {
  gateway, internalGatewayName, sectionName,
  name ? <chosen by gateway.tier>,
} -> parentRef
```

The parent-ref half of the above, for a floe whose route is not a plain
HTTPRoute. Picks the Gateway by `tier` unless `name` overrides it, which is
what a floe publishing a second route on the internal Gateway needs.

### `mkGatewayParent`

```nix
mkGatewayParent { name, sectionName, namespace ? null } -> parentRef
```

Builds one entry for an HTTPRoute's `parentRefs` from a name you have
already resolved. Prefer `mkGatewayParentFor`, which resolves it. Omits
`namespace` entirely when null, rather than emitting an explicit `null`.

### `mkHttpRoute` and `mkTlsRoute`

```nix
mkHttpRoute {
  name, namespace, hostname,
  gatewayParent,               # from mkGatewayParent
  backend,                     # { name; port; }
  pathPrefix ? "/",
  labels ? { },
} -> HTTPRoute
```

`mkTlsRoute` takes the same arguments minus `pathPrefix` and returns a
TLSRoute, for passthrough where the backend terminates TLS itself. It needs
the gateway's passthrough listener; see
`floes.gateway.exports.passthroughEnabled`.

### `mkCertificate`

```nix
mkCertificate {
  name, namespace, secretName,
  issuerRef,                   # { name; kind; }
  dnsNames,
  labels ? { },
} -> Certificate
```

Pass `config.floes.cert-manager.exports.defaultIssuerRef` as `issuerRef` for
public names, or `internalIssuerRef` for `*.svc` names. ACME issuers reject
those.

## `k8sHelpers.wait` (readiness)

From `lib/util/wait.nix`. Same probe DSL as a bundle's
[`readyProbe`](./bundles.md#readyprobe), but rendered into a container you
place yourself.

| Function                                     | Returns                                     |
| -------------------------------------------- | ------------------------------------------- |
| `renderProbe probe`                          | `{ image, command, args, volumeMounts? }`   |
| `mkWaitInitContainer { probe, name, … }`     | a container for `initContainers`            |
| `mkWaitJob { probe, serviceAccountName, … }` | a one-shot Job                              |
| `caBundleVolumeName`                         | the conventional volume name for the lab CA |

Use `mkWaitInitContainer` when a workload must not start until something
else is ready _and_ the wait needs the lab CA: a bundle's `readyProbe` runs
in a Pod with no ServiceAccount and so cannot mount it.

Probes using the kubectl-native kinds need the Pod's ServiceAccount to hold
`get`/`watch` on the probed resource. The helper does not create RBAC for
you.

## `catallaxy.lib`

Exported from `lib/pure.nix`. The stable public surface.

| Export                     | Signature                       | For                               |
| -------------------------- | ------------------------------- | --------------------------------- |
| `floe.mkFloe`              | see [mkFloe API](./floe-api.md) | authoring a floe                  |
| `floe.evalFloe`            | see [mkFloe API](./floe-api.md) | isolation testing                 |
| `floe.refs`                | capability and reference types  | floes with a typed interface      |
| `mkIdempotentJob`          | below                           | one-shot bootstrap Jobs           |
| `hashContent`              | `attrs -> 10-char sha256`       | content-addressing anything       |
| `mkNetworkPolicy`          | policy builder                  | cluster network policy            |
| `mkPreserveRuntimePatches` | kapp rebase rules               | preserving runtime-written fields |
| `network`                  | CIDR arithmetic                 | subnet maths in provisioners      |
| `evalModule`               | the lab evaluator               | building a lab outside `mkLab`    |

### `mkIdempotentJob`

```nix
mkIdempotentJob {
  name, namespace,
  contentInputs,               # anything that should invalidate the Job
  podSpec,
  extraLabels ? { },
  argoCDSyncWave ? "10",
  jobAnnotations ? { },
} -> { name, hash, resources }
```

Job specs are largely immutable, so a one-shot bootstrap Job that changes
becomes a permanent sync error. This suffixes the Job's name with a SHA256:
same content, same name, apply is a no-op. Changed content, new name, and a
new Job that runs.

The hash covers `contentInputs` **and `podSpec`**, so bumping an image tag
or reordering an `env` entry re-runs the Job just as editing the script
does. That is wider than it should be, and
[Runtime Effects](../understanding/runtime-effects.md) explains why and what
to do about it.

What happens to the previous Job depends on the deploy path: kapp and ArgoCD
prune it, and the plain server-side-apply path leaves it in the namespace.
The `<name>-runs` ConfigMap holds only the current generation's hash, not a
history.

`resources` contains both the Job and the ConfigMap, ready to splice into a
bundle's `resources`.

It sets `kapp.k14s.io/update-strategy: fallback-on-replace` and deliberately
does **not** set `argocd.argoproj.io/hook`: dual ownership between kapp and
an ArgoCD hook deadlocks deletion through the hook finalizer whenever the
owning Application is stuck.

`argoCDSyncWave` defaults to `"10"` so the Job runs after a chart's own
resources, which conventionally sit at wave 0.

## `cataCharts` (pinned charts)

Every chart the framework ships, version-pinned with a content hash in
`lib/charts.nix`:

```nix
cataCharts.<name> = { chart; crds; version; }
```

For the current set, ask the flake rather than trusting a list here:

```bash
nix eval --json .#legacyPackages.x86_64-linux.charts --apply builtins.attrNames
```

`crds` is separate from `chart` because CRDs generally belong in an earlier
bundle than the operator that consumes them.

A floe can also take a chart derivation from anywhere; `chart` is just
`types.package`.
