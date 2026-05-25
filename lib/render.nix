# lib/render.nix
#
# Build-time manifest rendering for the IR module system.
#
# This module provides functions to render IR outputs (helm charts, typed
# resources, raw yamls) into Kubernetes manifests at Nix build time.
# No IFDs are used - all rendering happens via runCommand derivations.
#
# Key functions:
# - renderHelmChart: Render a helm chart with optional kustomize patching
# - renderResources: Convert typed resources to YAML
# - renderPhase: Combine all outputs for a single phase
# - renderCluster: Full cluster manifest rendering

{ lib, pkgs }:

let
  inherit (lib)
    optionalString
    concatStringsSep
    mapAttrsToList
    filterAttrs
    ;

  # Convert an attribute set to a YAML file
  writeYamlFile = name: content: pkgs.writeText "${name}.yaml" (builtins.toJSON content);

  # Write helm values to a file
  writeValuesFile = name: values: pkgs.writeText "${name}-values.yaml" (builtins.toJSON values);

  # Convert a typed Kubernetes resource to its YAML representation
  resourceToYaml =
    name: resource:
    let
      # Build the resource structure, filtering out null values
      cleanResource =
        lib.filterAttrsRecursive (_: v: v != null) {
          inherit (resource) apiVersion kind;
          metadata = {
            name = resource.metadata.name or name;
          }
          // lib.optionalAttrs (resource.metadata.namespace or null != null) {
            inherit (resource.metadata) namespace;
          }
          // lib.optionalAttrs (resource.metadata.labels or { } != { }) {
            inherit (resource.metadata) labels;
          }
          // lib.optionalAttrs (resource.metadata.annotations or { } != { }) {
            inherit (resource.metadata) annotations;
          }
          // (removeAttrs (resource.metadata or { }) [
            "name"
            "namespace"
            "labels"
            "annotations"
          ]);
        }
        // lib.optionalAttrs (resource.spec or null != null) {
          inherit (resource) spec;
        }
        // lib.optionalAttrs (resource.data or null != null) {
          inherit (resource) data;
        }
        // lib.optionalAttrs (resource.stringData or null != null) {
          inherit (resource) stringData;
        }
        // (removeAttrs resource [
          "apiVersion"
          "kind"
          "metadata"
          "spec"
          "data"
          "stringData"
        ]);
    in
    cleanResource;

  # Recursively filter null values from an attrset
  filterAttrsRecursive =
    pred: attrs:
    lib.mapAttrs (
      name: value:
      if lib.isAttrs value && !(lib.isDerivation value) then filterAttrsRecursive pred value else value
    ) (lib.filterAttrs pred attrs);

  # Render a single helm chart to manifests
  # Supports optional kustomize patching
  renderHelmChart =
    name: spec:
    let
      valuesFile = writeValuesFile name spec.values;
      extraOptsStr = concatStringsSep " " spec.extraOpts;

      # Build kustomization.yaml for patching
      kustomizationContent = {
        apiVersion = "kustomize.config.k8s.io/v1beta1";
        kind = "Kustomization";
        resources = [ "helm-output.yaml" ] ++ spec.kustomize.resources;
      }
      // lib.optionalAttrs (spec.kustomize.patches != [ ]) {
        patches = spec.kustomize.patches;
      }
      // lib.optionalAttrs (spec.kustomize.patchesJson6902 != [ ]) {
        patchesJson6902 = spec.kustomize.patchesJson6902;
      };

      kustomizationFile = pkgs.writeText "kustomization.yaml" (builtins.toJSON kustomizationContent);

    in
    pkgs.runCommand "helm-${name}"
      {
        nativeBuildInputs = [
          pkgs.kubernetes-helm
          (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
        ]
        ++ lib.optional spec.kustomize.enable pkgs.kustomize;
      }
      ''
                mkdir -p $out work

                # 1. Render helm chart to YAML
                helm template ${spec.releaseName} ${spec.chart} \
                  --namespace ${spec.namespace} \
                  --values ${valuesFile} \
                  ${extraOptsStr} \
                  > work/helm-output.yaml

                # 1b. Inject namespace into namespaced resources that helm template didn't set.
                # Many charts omit metadata.namespace, relying on helm install --namespace.
                # Since we use helm template, we inject it for all non-cluster-scoped resources.
                # Uses a simple per-file Python script to avoid yq multi-doc pitfalls.
                python3 -c '
        import yaml, sys

        CLUSTER_SCOPED = {
            "Namespace", "ClusterRole", "ClusterRoleBinding",
            "CustomResourceDefinition",
            "ValidatingWebhookConfiguration", "MutatingWebhookConfiguration",
            "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding",
            "PriorityClass", "StorageClass", "IngressClass",
            "APIService",
        }
        ns = "${spec.namespace}"
        path = sys.argv[1]
        with open(path) as f:
            docs = list(yaml.safe_load_all(f))
        out = []
        for doc in docs:
            if doc and isinstance(doc, dict) and "kind" in doc:
                meta = doc.get("metadata") or {}
                if not meta.get("namespace") and doc["kind"] not in CLUSTER_SCOPED:
                    meta["namespace"] = ns
                    doc["metadata"] = meta
                out.append(doc)
        with open(path, "w") as f:
            yaml.dump_all(out, f, default_flow_style=False, sort_keys=False)
                ' work/helm-output.yaml

                ${optionalString spec.kustomize.enable ''
                  # 2. Apply kustomize patching
                  cp ${kustomizationFile} work/kustomization.yaml

                  # Copy any additional resources
                  ${concatStringsSep "\n" (
                    map (
                      r:
                      if lib.isPath r then
                        "cp ${r} work/"
                      else
                        "echo '${r}' > work/extra-$(echo '${r}' | sha256sum | cut -c1-8).yaml"
                    ) spec.kustomize.resources
                  )}

                  kustomize build work > $out/${name}.yaml
                ''}

                ${optionalString (!spec.kustomize.enable) ''
                  # No patching, just copy helm output
                  cp work/helm-output.yaml $out/${name}.yaml
                ''}

                # Verify output is valid YAML
                if [ ! -s "$out/${name}.yaml" ]; then
                  echo "Warning: Empty output for helm chart ${name}" >&2
                fi
      '';

  # Render typed resources to a YAML file
  renderResources =
    name: resources:
    let
      # Convert all resources to YAML-ready structures
      yamlDocs = mapAttrsToList resourceToYaml resources;

      # Combine into multi-document YAML
      combinedYaml = concatStringsSep "\n---\n" (map builtins.toJSON yamlDocs);

    in
    pkgs.writeText "${name}-resources.yaml" combinedYaml;

  # Render raw YAML entries (strings, paths, or derivations)
  # CRD files are automatically split by API group for manageability.
  renderYamls =
    name: yamls:
    pkgs.runCommand "${name}-yamls"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p $out
        ${concatStringsSep "\n" (
          lib.imap0 (
            i: yaml:
            if lib.isPath yaml || lib.isDerivation yaml then
              ''
                fname=$(basename ${yaml})
                fname="''${fname#*-}"

                if [ -f "${yaml}" ] && grep -q 'kind.*CustomResourceDefinition' "${yaml}"; then
                  # Split CRDs by spec.group
                  for group in $(yq -N '.spec.group // ""' "${yaml}" | sort -u | grep -v '^$'); do
                    yq "select(.spec.group == \"$group\")" "${yaml}" > "$out/${toString i}-$group.yaml"
                  done
                else
                  cp ${yaml} $out/${toString i}-$fname
                fi
              ''
            else
              "echo '${yaml}' > $out/${toString i}-inline.yaml"
          ) yamls
        )}
      '';

  # Render a complete phase to manifests
  renderPhase =
    phaseName: phaseConfig:
    let
      # Render all helm charts
      helmOutputs = lib.mapAttrs renderHelmChart phaseConfig.helmCharts;

      # Render typed resources if any
      hasResources = phaseConfig.resources != { };
      resourcesOutput = lib.optionalAttrs hasResources {
        resources = renderResources phaseName phaseConfig.resources;
      };

      # Render raw yamls if any
      hasYamls = phaseConfig.yamls != [ ];
      yamlsOutput = lib.optionalAttrs hasYamls {
        yamls = renderYamls phaseName phaseConfig.yamls;
      };

      # Combine all outputs into a single phase package
      allOutputs = helmOutputs // resourcesOutput // yamlsOutput;

    in
    pkgs.runCommand "phase-${phaseName}" { } ''
      mkdir -p $out

      ${concatStringsSep "\n" (
        mapAttrsToList (name: drv: ''
          if [ -d "${drv}" ]; then
            cp -r ${drv}/* $out/
          else
            cp ${drv} $out/${name}.yaml
          fi
        '') allOutputs
      )}

      # Create manifest index
      echo "${phaseName}" > $out/.phase-name
      ls -1 $out/*.yaml 2>/dev/null | wc -l > $out/.manifest-count || echo "0" > $out/.manifest-count
    '';

  # Render all phases for a cluster
  renderCluster =
    {
      config,
      clusterName ? config.cluster.name or "cluster",
    }:
    let
      irConfig = config.ir;
      phases = irConfig.phases;

      # Filter to phases that have content
      activePhasesNames = lib.filter (
        name:
        let
          p = phases.${name};
        in
        p.helmCharts != { } || p.resources != { } || p.yamls != [ ]
      ) (lib.attrNames phases);

      # Render each active phase
      renderedPhases = lib.genAttrs activePhasesNames (name: renderPhase name phases.${name});

      # Get ordered list of phases
      orderedPhases = lib.sort (a: b: phases.${a}.order < phases.${b}.order) activePhasesNames;

      # Create combined manifest package
      combinedManifests = pkgs.runCommand "manifests-${clusterName}" { } ''
        mkdir -p $out

        ${concatStringsSep "\n" (
          lib.imap0 (i: phaseName: ''
            mkdir -p $out/${toString i}-${phaseName}
            if [ -d "${renderedPhases.${phaseName}}" ]; then
              cp -r ${renderedPhases.${phaseName}}/* $out/${toString i}-${phaseName}/ 2>/dev/null || true
            fi
          '') orderedPhases
        )}

        # Create phase ordering file
        cat > $out/.phase-order << 'EOF'
        ${concatStringsSep "\n" orderedPhases}
        EOF

        # Create metadata
        echo "${clusterName}" > $out/.cluster-name
      '';

    in
    {
      # Per-phase manifest packages
      phases = renderedPhases;

      # Combined manifest package
      combined = combinedManifests;

      # Phase ordering information
      phaseOrder = orderedPhases;
    };

  # Create namespace resources for phases that need them
  renderNamespaces =
    namespaces:
    let
      nsResources = lib.genAttrs namespaces (ns: {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = ns;
      });
    in
    renderResources "namespaces" nsResources;

in
{
  inherit
    renderHelmChart
    renderResources
    renderYamls
    renderPhase
    renderCluster
    renderNamespaces
    resourceToYaml
    writeValuesFile
    writeYamlFile
    ;

  # Helper to apply common labels to a resource
  applyCommonLabels =
    labels: resource:
    resource
    // {
      metadata = (resource.metadata or { }) // {
        labels = (resource.metadata.labels or { }) // labels;
      };
    };

  # Helper to apply common annotations to a resource
  applyCommonAnnotations =
    annotations: resource:
    resource
    // {
      metadata = (resource.metadata or { }) // {
        annotations = (resource.metadata.annotations or { }) // annotations;
      };
    };
}
