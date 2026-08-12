# Nix Helpers

Two sources. `k8sHelpers` and `cataCharts` arrive as module arguments inside
a floe. Everything under `catallaxy.lib` is the flake's public API,
importable from a consumer flake.

## `k8sHelpers` (resource constructors)

From `lib/k8s-helpers.nix`. These exist so floes stop hand-writing Gateway
API and cert-manager shapes, and so a shape change lands in one place.

### `mkGatewayParent`

```nix
mkGatewayParent { name, sectionName, namespace ? null } -> parentRef
```

Builds one entry for an HTTPRoute's `parentRefs`. Omits `namespace` entirely
when null, rather than emitting an explicit `null`.

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
becomes a permanent sync error. This suffixes the Job's name with a SHA256
of `contentInputs`: same content, same name, apply is a no-op. Changed
content, new name, new Job beside the old one. An owning `<name>-runs`
ConfigMap accumulates the hash history as an audit trail.

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
