# Phases

Phases control the order in which Kubernetes resources are deployed. Not all resources can be applied at once -- CRDs must exist before custom resources that use them, operators must be running before their managed resources are created, and databases should be ready before applications that depend on them.

Each phase has a numeric `order` (lower values deploy first) and a `dependsOn` list that declares explicit dependencies on other phases. Components write their resources into phase bundles, and the CLI applies phases in order.

## Built-in phases

| Phase | Order | Depends on | Description |
|-------|-------|------------|-------------|
| **crds** | -10 | -- | Custom Resource Definitions. Deployed first so that all subsequent phases can create custom resources. |
| **namespaces** | -5 | crds | Namespace creation. Ensures target namespaces exist before resources are deployed into them. |
| **networking** | 0 | namespaces | CNI (Cilium), Gateway API controller (Traefik), and core networking. Must be ready before anything that needs pod networking or ingress. |
| **operators** | 10 | networking | Operator deployments: cert-manager, external-dns, trust-manager, CNPG operator, kaniop, and others. These controllers must be running before their custom resources are created in later phases. |
| **secrets** | 20 | operators | Secret management: external-secrets stores, SOPS decryption, and generated secrets. Depends on operators because some secrets are managed by operator-created controllers. |
| **infrastructure** | 30 | operators, secrets | Core infrastructure services: Kanidm, Prometheus, Loki, Tempo, Zot registry, and similar. These are long-running services that applications depend on. |
| **gitops** | 40 | operators, secrets | GitOps controllers: ArgoCD. Deployed after operators and secrets so that it has access to credentials and can manage application delivery. |
| **databases** | 50 | operators, secrets | Database instances: CNPG PostgreSQL clusters, Redis. Depends on operators (for the database controllers) and secrets (for credentials). |
| **apps** | 90 | infrastructure, databases | Applications: Forgejo, Grafana, and custom apps. Deployed late because they typically depend on databases, identity providers, and other infrastructure. |
| **workloads** | 100 | infrastructure, databases | User workloads. The final phase for anything that depends on the full platform being ready. |

## Phase configuration options

Each phase supports these options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `order` | int | (varies) | Numeric ordering. Lower values deploy first. |
| `dependsOn` | list of strings | (varies) | Phases that must complete before this one. |
| `keepResources` | bool | `false` | Prevent deletion of resources in this phase. |
| `pruneStrategy` | enum | `"default"` | `"default"`, `"never"`, or `"orphan"`. Controls resource cleanup. |
| `waitForReady` | bool | `true` | Wait for all resources to become ready before proceeding. |
| `timeout` | string | `"10m"` | Timeout for this phase's deployment. |
| `waitForCRDs` | bool | `false` | Wait for CRDs to be established before deploying. |
| `crdNames` | list of strings | `[]` | CRD names to wait for when `waitForCRDs` is true. |
| `bundles` | attrs | `{}` | Bundles of resources belonging to this phase. |

## Bundles

Each phase contains bundles. A bundle is the finest-grained deployment unit and contains:

- `helmCharts` -- Helm charts to template and deploy
- `resources` -- Typed Kubernetes resource definitions (Nix attribute sets)
- `yamls` -- Raw YAML manifests (strings or file paths)
- `createNamespaces` -- Namespaces to create for this bundle

Components write into bundles by setting `phases.<phase>.bundles.<component-name>`. Multiple components can write to the same phase but use separate bundles.

## Custom phases

You can define custom phases for specialized ordering needs:

```nix
phases.pre-apps = {
  order = 85;
  dependsOn = [ "infrastructure" "databases" ];
  waitForReady = true;
  timeout = "5m";
};
```

Components can target custom phases via their `phase` option:

```nix
components.custom.apps.my-app.phase = "pre-apps";
```

## Why ordering matters

Without phase ordering, common failures include:

- Custom resources applied before their CRDs exist (API server rejects them)
- Pods scheduled before the CNI is running (they never get an IP)
- Applications starting before their databases are ready (crash loops)
- OAuth2 clients created before the identity provider is running (registration fails)
- Certificate requests submitted before cert-manager's webhook is ready (timeouts)

Phases encode these dependencies declaratively so that the CLI (or GitOps engine) applies resources in a safe order every time.
