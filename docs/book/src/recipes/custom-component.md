# Custom Components

The `components.custom.apps` option lets you deploy your own applications alongside the built-in infrastructure components. Custom apps support Helm charts, typed Kubernetes resources, raw YAML, and optional Gateway API routing -- all without writing a full component module.

## Example: Helm chart deployment

Deploy an application using a Helm chart:

```nix
# In your cluster configuration
{ cataCharts, ... }:
{
  components.custom.apps.my-app = {
    namespace = "my-app";
    phase = "apps";

    helmCharts.my-app = {
      chart = cataCharts.my-app.chart;  # if registered in lib/charts.nix
      # or use an inline chart path
      namespace = "my-app";
      values = {
        replicas = 2;
        image.tag = "v1.2.3";
        ingress.enabled = false;  # use Gateway API instead
      };
    };
  };
}
```

The chart is rendered at Nix build time and deployed during the specified phase. The namespace is created automatically unless you set `createNamespace = false`.

## Example: Resources with a Gateway route

Deploy raw Kubernetes resources and expose them via the Gateway API:

```nix
{ config, lib, ... }:
let
  labDomain = config.cluster.lab.domain;  # e.g., "homelab.test"
in
{
  components.custom.apps.whoami = {
    namespace = "whoami";
    phase = "apps";

    resources = {
      whoami-deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = "whoami";
          namespace = "whoami";
        };
        spec = {
          replicas = 1;
          selector.matchLabels.app = "whoami";
          template = {
            metadata.labels.app = "whoami";
            spec.containers = [
              {
                name = "whoami";
                image = "traefik/whoami:v1.10";
                ports = [ { containerPort = 80; } ];
              }
            ];
          };
        };
      };

      whoami-service = {
        apiVersion = "v1";
        kind = "Service";
        metadata = {
          name = "whoami";
          namespace = "whoami";
        };
        spec = {
          selector.app = "whoami";
          ports = [
            {
              port = 80;
              targetPort = 80;
            }
          ];
        };
      };
    };

    gateway = {
      enable = true;
      domain = "whoami.${labDomain}";
      serviceName = "whoami";
      servicePort = 80;
    };
  };
}
```

When `gateway.enable = true`, Catallaxy automatically generates an `HTTPRoute` (or `TLSRoute` for passthrough mode) pointing to your service. The route is added to the same bundle as your resources.

## Gateway options

| Option | Default | Description |
|--------|---------|-------------|
| `gateway.enable` | `false` | Generate a Gateway API route |
| `gateway.mode` | `"terminate"` | `"terminate"` for HTTPRoute, `"passthrough"` for TLSRoute |
| `gateway.domain` | `""` | Hostname for the route |
| `gateway.serviceName` | app name | Backend service name |
| `gateway.servicePort` | `80` | Backend service port |
| `gateway.gatewayRef` | `"default-gateway"` | Name of the Gateway resource to attach to |
| `gateway.gatewayNamespace` | `"kube-system"` | Namespace of the Gateway resource |

## Custom app options reference

| Option | Default | Description |
|--------|---------|-------------|
| `enable` | `true` | Whether to deploy this app |
| `phase` | `"apps"` | Deployment phase |
| `namespace` | app name | Kubernetes namespace |
| `createNamespace` | `true` | Auto-create the namespace |
| `helmCharts` | `{}` | Helm charts (same shape as phase bundle helmCharts) |
| `resources` | `{}` | Typed Kubernetes resource definitions |
| `yamls` | `[]` | Raw YAML manifests (strings or paths) |

## When to use custom apps vs. a full component

Use `components.custom.apps` when:

- You need to deploy an application that is specific to your lab.
- The app does not need cross-component `ref` wiring.
- You want a quick deployment without writing a module.

Write a full component module (see [Adding Components](../contributing/adding-components.md)) when:

- Other components need to reference this component via `ref` attributes.
- The component has complex configuration options that benefit from the NixOS module type system.
- You intend to contribute the component upstream.
