# Components Overview

Catallaxy ships with built-in components. Each component is a self-contained module that declares configuration options and writes Kubernetes resources into deployment phases when enabled.

Components are defined in `modules/lab/cluster/components/`. Enable them in your cluster configuration with `components.<name>.enable = true`.

## Component catalog

### CNI

| Component  | Description                                                                                                 |
| ---------- | ----------------------------------------------------------------------------------------------------------- |
| **cilium** | eBPF-based CNI and network policy engine. Provides pod networking, service mesh, and network observability. |

### Gateway

| Component   | Description                                                                                                                         |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **gateway** | Gateway API controller (Traefik). Manages ingress via HTTPRoute and TLSRoute resources. Configures TLS termination and passthrough. |

### PKI

| Component         | Description                                                                                        |
| ----------------- | -------------------------------------------------------------------------------------------------- |
| **cert-manager**  | X.509 certificate management. Automates certificate issuance and renewal using the lab CA or ACME. |
| **trust-manager** | Distributes CA bundles across namespaces as ConfigMaps. Ensures all services trust the lab CA.     |

### Observability

| Component          | Description                                                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| **prometheus**     | Metrics collection and alerting (kube-prometheus-stack). Includes Prometheus, Alertmanager, and recording/alerting rules.            |
| **grafana**        | Dashboards and visualization. Connects to Prometheus, Loki, and Tempo as data sources. Supports OIDC login via Kanidm.               |
| **loki**           | Log aggregation. Receives logs from OpenTelemetry collectors and provides LogQL query interface.                                     |
| **tempo**          | Distributed tracing backend. Receives traces via OTLP and integrates with Grafana.                                                   |
| **otel-collector** | OpenTelemetry Collector. Deployed as agent (DaemonSet) and/or gateway (Deployment) to collect and forward logs, metrics, and traces. |

### Databases

| Component          | Description                                                                                                   |
| ------------------ | ------------------------------------------------------------------------------------------------------------- |
| **cnpg**           | CloudNativePG operator. Manages PostgreSQL clusters with automated failover, backups, and connection pooling. |
| **redis-operator** | Redis operator. Manages Redis instances and clusters.                                                         |

### Filesystems

| Component     | Description                                                                                            |
| ------------- | ------------------------------------------------------------------------------------------------------ |
| **openebs**   | Local persistent volume provisioner. Provides storage classes backed by node-local paths.              |
| **seaweedfs** | Distributed object storage. Provides S3-compatible storage for backups, Loki chunks, and Tempo blocks. |

### Registries

| Component | Description                                                                                      |
| --------- | ------------------------------------------------------------------------------------------------ |
| **zot**   | OCI-compliant container registry. Lightweight registry for local image caching and distribution. |

### Secrets

| Component            | Description                                                                       |
| -------------------- | --------------------------------------------------------------------------------- |
| **external-secrets** | Syncs secrets from external providers (Vault, AWS, etc.) into Kubernetes Secrets. |
| **sops**             | SOPS-based secret decryption. Decrypts encrypted secret files at deployment time. |

### Identity

| Component  | Description                                                                                                           |
| ---------- | --------------------------------------------------------------------------------------------------------------------- |
| **kanidm** | Identity provider. Provides OIDC/OAuth2 authentication, user management, and WebAuthn/TOTP support.                   |
| **kaniop** | Kanidm operator. Declaratively manages Kanidm users, groups, and OAuth2 client registrations as Kubernetes resources. |

### GitOps

| Component  | Description                                                                                                         |
| ---------- | ------------------------------------------------------------------------------------------------------------------- |
| **argocd** | Argo CD continuous delivery. Manages application deployments from Git repositories. Supports OIDC login via Kanidm. |

### Source Control

| Component   | Description                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------ |
| **forgejo** | Self-hosted Git forge. Lightweight GitHub/Gitea alternative with OAuth2 login, issue tracking, and CI integration. |

### Provisioning

| Component       | Description                                                                                                       |
| --------------- | ----------------------------------------------------------------------------------------------------------------- |
| **cluster-api** | Cluster API operator (CAPI). Provisions and manages Kubernetes clusters declaratively.                            |
| **crossplane**  | Crossplane universal control plane. Manages cloud infrastructure (DNS, compute, storage) as Kubernetes resources. |

### DNS

| Component        | Description                                                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------- |
| **external-dns** | Synchronizes Kubernetes Gateway/Ingress resources with external DNS providers (CoreDNS, Cloudflare, Route53). |

### VPN

| Component   | Description                                                                                    |
| ----------- | ---------------------------------------------------------------------------------------------- |
| **netbird** | WireGuard-based mesh VPN. Provides secure connectivity between clusters and external networks. |

### Backups

| Component  | Description                                                                                                  |
| ---------- | ------------------------------------------------------------------------------------------------------------ |
| **velero** | Cluster backup and restore. Supports scheduled backups to S3-compatible storage and cross-cluster migration. |

### Custom

| Component  | Description                                                                                                                                                                                                                                             |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **custom** | Deploy custom applications using `components.custom.apps.<name>`. Supports Helm charts, typed resources, raw YAML, and Gateway API routing without writing a full component module. See the [Custom Components recipe](../recipes/custom-component.md). |

## Cross-component wiring

Components expose computed values through `ref` attributes. These are always available, even when the component is disabled, allowing safe cross-references:

```nix
{ config, ... }:
let
  certManagerRef = config.components.cert-manager.ref;
  kanidmRef = config.components.kanidm.ref;
in
{
  # Use certManagerRef.caBundleConfigMap, kanidmRef.oidcEndpoint, etc.
}
```

For cross-cluster references, use the `lab` argument:

```nix
{ lab, ... }:
{
  components.otel-collector.exporters.otlp.endpoint =
    lab.clusters.obs.components.tempo.ref.otlpGrpc;
}
```

See [Adding Components](../contributing/adding-components.md) for the full component authoring guide.
