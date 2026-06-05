# Lint System

Catallaxy's lint system validates rendered manifests against universal properties. It's the primary mechanism for catching configuration errors before deployment.

## Built-in Checks

| Check | What it validates |
|-------|-------------------|
| `schema` | Every resource has apiVersion, kind, metadata.name |
| `identity` | No duplicate (apiVersion, kind, namespace, name) tuples |
| `prefix` | Resources and namespaces use the lab prefix |
| `selector` | Service selectors match workload pod labels |
| `reference` | ConfigMap/Secret references point to existing resources |
| `projection-ref` | secretKeyRef names match declared projections with correct phase/namespace |
| `image-pin` | Container images use digest pins and approved registries |
| `crd-schema` | Custom Resources validate against CRD OpenAPI schemas |
| `missing-crd` | Warns when a CR has no matching CRD in the manifest set |

## Running Lint

```bash
cata lab lint                # Lint the default lab
cata lab lint --path <pkg>   # Lint a pre-built lab package
```

In CI, `nix flake check` runs lint on all example labs automatically.

## Skipping Checks

Per-resource:
```yaml
metadata:
  annotations:
    catallaxy.io/lint-skip: reference,image-pin
```

Per-run:
```bash
cata lab lint --skip image-pin --skip crd-schema
```

## Custom Lint Checks

Define custom property checks in Nix that run shell commands on rendered manifests:

```nix
lab.lint.checks = {
  no-default-namespace = {
    description = "Resources must not use the default namespace";
    severity = "error";
    command = ''
      results=$(yq -N 'select(.metadata.namespace == "default") | .metadata.name' "$FILE" 2>/dev/null)
      if [ -n "$results" ]; then
        echo "Found resources in default namespace: $results"
        exit 1
      fi
    '';
  };

  no-latest-tags = {
    description = "Container images must not use :latest";
    severity = "warning";
    command = ''
      results=$(yq -N '
        select(.kind == "Deployment" or .kind == "StatefulSet") |
        .spec.template.spec.containers[] |
        select(.image | test(":latest$")) |
        .image
      ' "$FILE" 2>/dev/null)
      if [ -n "$results" ]; then
        echo "$results"
        exit 1
      fi
    '';
  };

  require-resource-limits = {
    description = "Containers must have resource limits";
    severity = "warning";
    command = ''
      results=$(yq -N '
        select(.kind == "Deployment" or .kind == "StatefulSet") |
        .spec.template.spec.containers[] |
        select(.resources.limits == null) |
        .name
      ' "$FILE" 2>/dev/null)
      if [ -n "$results" ]; then
        echo "Missing resource limits: $results"
        exit 1
      fi
    '';
  };
};
```

### Shell Command Interface

Each check receives:
- `$FILE` — path to a YAML manifest file
- `$CLUSTER` — name of the cluster being checked

Available tools: `yq`, `jq`, standard Unix tools.

Return values:
- **Exit 0** → check passes
- **Non-zero** → check fails; stdout becomes the diagnostic message

### Severity

- `"error"` — fails the lint (non-zero exit from `cata lab lint`)
- `"warning"` — reported but doesn't fail

## Nix Assertions (Config-Level Properties)

For properties that can be checked at Nix evaluation time (before rendering), use assertions:

```nix
config.assertions = [
  {
    assertion = config.components.my-app.enable -> config.components.cnpg.enable;
    message = "my-app requires PostgreSQL (enable components.cnpg)";
  }
  {
    assertion = config.cluster.security.networkPolicies.enable || !config.components.my-app.enable;
    message = "my-app requires network policies to be enabled";
  }
];
```

Assertions fire at `nix eval` time — before any manifests are rendered. They catch configuration-level contradictions immediately.

## Testing Strategy

Catallaxy's testing is property-based:

1. **Nix assertions** — config-level properties checked at eval time
2. **Lint checks** — manifest-level properties checked on rendered YAML
3. **E2E** — deploy examples and verify they work

```bash
nix flake check     # Runs lint on all example labs (CI-friendly)
cata lab up          # E2E: deploy and verify
cata lab down        # Clean up
```

No traditional unit tests — correctness comes from universal properties that hold across all configurations.
