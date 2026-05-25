{
  lib,
  k8sVersion ? "1.31",
}:

let
  inherit (lib) mkOption types;

  # Import generated types
  generatedTypes = import ./generated/index.nix { inherit lib; };

  # Get versioned types (k8s + CRDs)
  versionedTypes = generatedTypes.forVersion k8sVersion;

  # Flatten all resource types into { Kind = type; ... }
  allResourceTypes = generatedTypes.flattenTypes versionedTypes;

  # ObjectMeta type for resource metadata
  metadataType = import ./generated/k8s-api.nix;

  # Kustomize patching options for helm charts
  kustomizeType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable kustomize-based patching of helm output";
      };

      patches = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          Strategic merge patches to apply to helm output.
          Each patch is an attribute set that will be merged with matching resources.
        '';
      };

      patchesJson6902 = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = ''
          JSON Patch (RFC 6902) operations to apply to helm output.
        '';
      };

      resources = mkOption {
        type = types.listOf (types.either types.path types.str);
        default = [ ];
        description = ''
          Additional resources to include alongside helm output.
          Can be paths to YAML files or inline YAML strings.
        '';
      };
    };
  };

  # Helm chart specification
  helmChartType = types.submodule (
    { name, ... }:
    {
      options = {
        chart = mkOption {
          type = types.package;
          description = "Helm chart derivation";
        };

        releaseName = mkOption {
          type = types.str;
          default = name;
          description = "Helm release name (defaults to attribute name)";
        };

        namespace = mkOption {
          type = types.str;
          default = "default";
          description = "Kubernetes namespace for the release";
        };

        values = mkOption {
          type = types.attrs;
          default = { };
          description = "Helm values to pass to the chart";
        };

        kustomize = mkOption {
          type = kustomizeType;
          default = { };
          description = "Kustomize patching configuration";
        };

        extraOpts = mkOption {
          type = types.listOf types.str;
          default = [ "--skip-tests" ];
          description = "Extra options to pass to helm template";
        };

        createNamespace = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to create the namespace if it doesn't exist";
        };
      };
    }
  );

  # Kubernetes resource type — dispatches to generated types by `kind`.
  # If the kind matches a generated type (k8s or CRD), use its typed submodule.
  # Otherwise, fall back to a freeform submodule for unknown kinds.
  kubernetesResourceType = types.submodule (
    { name, config, ... }:
    let
      # Look up the generated type for this resource's kind
      kindType = allResourceTypes.${config.kind} or null;
    in
    {
      options = {
        apiVersion = mkOption {
          type = types.str;
          description = "Kubernetes API version (e.g., 'v1', 'apps/v1')";
        };

        kind = mkOption {
          type = types.str;
          description = "Kubernetes resource kind (e.g., 'Service', 'Deployment')";
        };

        metadata = mkOption {
          type = types.submodule metadataType;
          default = {
            name = name;
          };
          description = "Resource metadata";
        };

        spec = mkOption {
          type = types.nullOr types.attrs;
          default = null;
          description = "Resource spec (structure depends on kind)";
        };

        data = mkOption {
          type = types.nullOr (types.attrsOf types.str);
          default = null;
          description = "Data for ConfigMap/Secret resources";
        };

        stringData = mkOption {
          type = types.nullOr (types.attrsOf types.str);
          default = null;
          description = "String data for Secret resources";
        };
      };
      # Allow any additional fields for flexibility
      freeformType = types.attrs;
    }
  );

  # bundle specification - contains all outputs for a deployment bundle
  # A collection of k8s resources that get packed and deployed together
  bundleType = types.submodule (
    { name, ... }:
    {
      options = {
        resources = mkOption {
          type = types.attrsOf kubernetesResourceType;
          default = { };
          description = ''
            Typed Kubernetes resources to include in this phase.
            Resources are validated against the generated K8s ${k8sVersion} API types and CRD types.
          '';
        };

        yamls = mkOption {
          type = types.listOf (types.either types.str types.path);
          default = [ ];
          description = ''
            Raw YAML manifests to include in this phase.
            Use this as an escape hatch when typed resources don't fit.
            Can be inline strings or paths to YAML files.
          '';
        };

        helmCharts = mkOption {
          type = types.attrsOf helmChartType;
          default = { };
          description = ''
            Helm charts to render for this phase.
            Charts are rendered at build time using helm template,
            with optional kustomize patching.
          '';
        };

        createNamespaces = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Namespaces to create for this phase";
        };
      };
    }
  );

in
{
  inherit
    kustomizeType
    helmChartType
    kubernetesResourceType
    bundleType
    ;

  # Export generated types for consumers
  inherit generatedTypes;

  # All flattened resource types (k8s + CRDs) for the selected version
  inherit allResourceTypes;

  # Convenience access to K8s types for the selected version
  k8sTypes = versionedTypes;

  # Get types for a specific K8s version
  forK8sVersion = generatedTypes.forVersion;
}
