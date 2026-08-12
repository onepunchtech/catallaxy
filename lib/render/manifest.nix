{ lib, pkgs }:

let
  inherit (lib)
    optionalString
    concatStringsSep
    mapAttrsToList
    filterAttrs
    ;

  writeYamlFile = name: content: pkgs.writeText "${name}.yaml" (builtins.toJSON content);

  writeValuesFile = name: values: pkgs.writeText "${name}-values.yaml" (builtins.toJSON values);

  resourceToYaml =
    name: resource:
    let

      stripNulls =
        v:
        if lib.isAttrs v && !(lib.isDerivation v) then
          lib.mapAttrs (_: stripNulls) (lib.filterAttrs (_: x: x != null) v)
        else if lib.isList v then
          map stripNulls (lib.filter (x: x != null) v)
        else
          v;

      cleanResource = stripNulls (
        {
          inherit (resource) apiVersion kind;
          metadata = {
            name = resource.metadata.name or name;
            labels = resource.metadata.labels or { };
            annotations = resource.metadata.annotations or { };
          }
          // lib.optionalAttrs (resource.metadata.namespace or null != null) {
            inherit (resource.metadata) namespace;
          }
          // lib.optionalAttrs (resource.metadata.finalizers or [ ] != [ ]) {
            inherit (resource.metadata) finalizers;
          }
          // lib.optionalAttrs (resource.metadata.ownerReferences or [ ] != [ ]) {
            inherit (resource.metadata) ownerReferences;
          }
          // (removeAttrs (resource.metadata or { }) [
            "name"
            "namespace"
            "labels"
            "annotations"
            "finalizers"
            "ownerReferences"
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
        ])
      );
    in
    cleanResource;

  filterAttrsRecursive =
    pred: attrs:
    lib.mapAttrs (
      name: value:
      if lib.isAttrs value && !(lib.isDerivation value) then filterAttrsRecursive pred value else value
    ) (lib.filterAttrs pred attrs);

  renderHelmChart =
    name: spec:
    let
      valuesFile = writeValuesFile name spec.values;
      extraOptsStr = concatStringsSep " " spec.extraOpts;

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
          pkgs.yq-go
        ]
        ++ lib.optional spec.kustomize.enable pkgs.kustomize;
      }
      ''
        mkdir -p $out work

        helm template ${spec.releaseName} ${spec.chart} \
          --namespace ${spec.namespace} \
          --values ${valuesFile} \
          ${extraOptsStr} \
          > work/helm-output.yaml

        yq -i '
          select(tag == "!!map" and has("kind"))
          | select((.metadata.annotations."helm.sh/hook" // "") == "")
          | .metadata = (.metadata // {})
          | (
              select(
                (.metadata.namespace // "") == ""
                and (
                  .kind as $k
                  | [
                      "Namespace", "ClusterRole", "ClusterRoleBinding",
                      "CustomResourceDefinition",
                      "ValidatingWebhookConfiguration", "MutatingWebhookConfiguration",
                      "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding",
                      "PriorityClass", "StorageClass", "IngressClass",
                      "APIService"
                    ]
                  | map(. == $k)
                  | any
                  | not
                )
              )
              | .metadata.namespace
            ) = "${spec.namespace}"
          | .metadata |= (
              del(.finalizers | select(. == null or length == 0))
              | del(.ownerReferences | select(. == null or length == 0))
              | .annotations = (.annotations // {})
              | .labels = (.labels // {})
            )
          | (select(.spec.template.metadata != null) | .spec.template.metadata) |= (
              del(.finalizers | select(. == null or length == 0))
              | del(.ownerReferences | select(. == null or length == 0))
              | .annotations = (.annotations // {})
              | .labels = (.labels // {})
            )
          | (
              select(.spec.jobTemplate.spec.template.metadata != null)
              | .spec.jobTemplate.spec.template.metadata
            ) |= (
              del(.finalizers | select(. == null or length == 0))
              | del(.ownerReferences | select(. == null or length == 0))
              | .annotations = (.annotations // {})
              | .labels = (.labels // {})
            )
          | (
              select(.spec.volumeClaimTemplates != null)
              | .spec.volumeClaimTemplates[].metadata
              | select(. != null)
            ) |= (
              del(.finalizers | select(. == null or length == 0))
              | del(.ownerReferences | select(. == null or length == 0))
              | .annotations = (.annotations // {})
              | .labels = (.labels // {})
            )
        ' work/helm-output.yaml

        ${optionalString spec.kustomize.enable ''
          cp ${kustomizationFile} work/kustomization.yaml

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
          cp work/helm-output.yaml $out/${name}.yaml
        ''}

        if [ ! -s "$out/${name}.yaml" ]; then
          echo "Warning: Empty output for helm chart ${name}" >&2
        fi
      '';

  rolloutWaitedKinds = [
    "Deployment"
    "StatefulSet"
    "DaemonSet"
  ];

  markDeferredWorkloads = lib.mapAttrs (
    _: resource:
    if lib.elem (resource.kind or "") rolloutWaitedKinds then
      lib.recursiveUpdate resource {
        metadata.annotations."catallaxy.io/await-rollout" = "false";
      }
    else
      resource
  );

  renderResources =
    name: resources:
    let

      yamlDocs = mapAttrsToList resourceToYaml resources;

      combinedYaml = concatStringsSep "\n---\n" (map builtins.toJSON yamlDocs);

    in
    pkgs.writeText "${name}-resources.yaml" combinedYaml;

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

  renderBundle =
    bundleKey: bundleConfig:
    let
      sanitize = builtins.replaceStrings [ "/" ] [ "__" ] bundleKey;
      helmOutputs = lib.mapAttrs renderHelmChart bundleConfig.helmCharts;
      hasResources = bundleConfig.resources != { };
      resourcesOutput = lib.optionalAttrs hasResources {
        resources = renderResources sanitize (
          if bundleConfig.awaitRollout or true then
            bundleConfig.resources
          else
            markDeferredWorkloads bundleConfig.resources
        );
      };
      hasYamls = bundleConfig.yamls != [ ];
      yamlsOutput = lib.optionalAttrs hasYamls {
        yamls = renderYamls sanitize bundleConfig.yamls;
      };
      allOutputs = helmOutputs // resourcesOutput // yamlsOutput;
    in
    pkgs.runCommand "bundle-${sanitize}" { } ''
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
      echo "${bundleKey}" > $out/.bundle-key
    '';

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
    renderBundle
    renderNamespaces
    resourceToYaml
    writeValuesFile
    writeYamlFile
    ;

  applyCommonLabels =
    labels: resource:
    resource
    // {
      metadata = (resource.metadata or { }) // {
        labels = (resource.metadata.labels or { }) // labels;
      };
    };

  applyCommonAnnotations =
    annotations: resource:
    resource
    // {
      metadata = (resource.metadata or { }) // {
        annotations = (resource.metadata.annotations or { }) // annotations;
      };
    };
}
