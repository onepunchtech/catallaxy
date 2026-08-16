{
  lib,
  pkgs,
  dirBuilder,
  yamlUtil,
  prefixUtil,
  imageUtil,
}:

{
  clusterName,
  prefix ? "",
  imageLock ? { },
  imageRegistry ? null,
  imageExempt ? [ ],
  imageOverrides ? { },
  labNamespaces ? [ ],

  packages,
  deployConfig,

  waves ? [ ],

  bootstrapMethod ? "kapp",
}:

let
  inherit (lib)
    concatStringsSep
    imap0
    fixedWidthString
    mapAttrsToList
    optionalAttrs
    ;

  appName = name: if prefix == "" then name else "${prefix}-${name}";

  sanitize = key: builtins.replaceStrings [ "/" ] [ "__" ] key;

  sanitizeName = key: lib.toLower (builtins.replaceStrings [ "/" "_" ] [ "-" "-" ] key);

  migrationManagerFor =
    b:
    if b == "kapp" then
      "kapp"
    else if b == "kubectl-ssa" then
      "catallaxy-bootstrap"
    else if b == "helm" then
      "helm"
    else
      null;

  migrationManager = migrationManagerFor bootstrapMethod;

  bundleEntries = lib.concatLists (
    imap0 (
      i: bundles:
      map (b: {
        bundleKey = b.name;
        waveIndex = i;
      }) (lib.filter (b: !(lib.hasPrefix "projection/" b.name)) bundles)
    ) waves
  );

  mkApplication =
    entry:
    let
      inherit (entry) bundleKey waveIndex;
      sanitized = sanitize bundleKey;
    in
    {
      name = sanitized;
      value = {
        apiVersion = "argoproj.io/v1alpha1";
        kind = "Application";
        metadata = {
          name = appName "${clusterName}-${sanitizeName bundleKey}";
          namespace = "argocd";
          annotations = {
            "argocd.argoproj.io/sync-wave" = toString waveIndex;
          }
          // optionalAttrs (migrationManager != null) {
            "argocd.argoproj.io/client-side-apply-migration-manager" = migrationManager;
          }
          // {
            "argocd.argoproj.io/compare-options" = "IncludeMutationWebhook=true";
          };
        };
        spec = {
          project = "default";
          source = {
            repoURL = deployConfig.repoUrl;
            targetRevision = deployConfig.targetBranch;
            path = "${deployConfig.targetPath}/bundles/${sanitized}";
            directory.recurse = true;
          };
          destination = {
            server = "https://kubernetes.default.svc";
          };

          ignoreDifferences =
            let
              workloadRule = kind: {
                group = "apps";
                inherit kind;
                jsonPointers = [
                  "/spec/selector"
                  "/spec/template/metadata/labels/kapp.k14s.io~1app"
                  "/spec/template/metadata/labels/kapp.k14s.io~1association"
                ];
              };
            in
            map workloadRule [
              "Deployment"
              "StatefulSet"
              "DaemonSet"
              "ReplicaSet"
            ];
          syncPolicy = {
            automated = {
              prune = true;
              selfHeal = true;
            };
            syncOptions = [
              "ServerSideApply=true"
              "RespectIgnoreDifferences=true"
            ];
          };
        };
      };
    };

  applicationEntries = lib.listToAttrs (map mkApplication bundleEntries);

  rootApplication = {
    apiVersion = "argoproj.io/v1alpha1";
    kind = "Application";
    metadata = {
      name = appName "${clusterName}-root";
      namespace = "argocd";
      labels."app.kubernetes.io/managed-by" = "catallaxy";
    };
    spec = {
      project = "default";
      source = {
        repoURL = deployConfig.repoUrl;
        targetRevision = deployConfig.targetBranch;
        path = "${deployConfig.targetPath}/applications";
        directory.recurse = true;
      };
      destination = {
        server = "https://kubernetes.default.svc";
        namespace = "argocd";
      };
      syncPolicy = {
        automated = {
          prune = true;
          selfHeal = true;
        };
        syncOptions = [
          "CreateNamespace=false"
        ];
      };
    };
  };

  rootApplicationFile =
    pkgs.runCommand "argocd-${clusterName}-root-app"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        echo '${builtins.toJSON rootApplication}' | yq -P '.' > $out
      '';

  applicationsDir =
    pkgs.runCommand "argocd-${clusterName}-apps"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p $out
        ${concatStringsSep "\n" (
          mapAttrsToList (name: app: ''
            echo '${builtins.toJSON app}' | yq -P '.' > "$out/${name}.yaml"
          '') applicationEntries
        )}
      '';

  bundlesDir =
    pkgs.runCommand "argocd-${clusterName}-bundles"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p $out
        ${concatStringsSep "\n" (
          map (
            entry:
            let
              inherit (entry) bundleKey;
              sanitized = sanitize bundleKey;
              pkg = packages.${bundleKey} or null;
            in
            if pkg == null then
              ""
            else
              ''
                mkdir -p "$out/${sanitized}"
                if [ -d "${pkg}" ]; then
                  cp -r --no-preserve=mode ${pkg}/* "$out/${sanitized}/" 2>/dev/null || true
                else
                  cp --no-preserve=mode ${pkg} "$out/${sanitized}/manifests.yaml"
                fi

                find "$out/${sanitized}" -name '*.yaml' -type f | while read -r f; do
                  yq -P -i '.' "$f" 2>/dev/null || true
                done

                ${lib.optionalString (bootstrapMethod != "kapp") ''
                  find "$out/${sanitized}" -name '*.yaml' -type f | while read -r f; do
                    yq -i '(.. | select(has("metadata")).metadata) |= (
                             with_entries(select(
                               ((.key == "labels") and (.value | length) == 0) | not
                             ))
                           )' "$f" 2>/dev/null || true
                  done
                ''}

                find "$out/${sanitized}" -name '*.yaml' -type f | while read -r f; do
                  if grep -q '^apiVersion: kapp.k14s.io/' "$f" 2>/dev/null; then
                    yq -i 'select(.apiVersion | test("^kapp\\.k14s\\.io/") | not)' "$f" 2>/dev/null || true
                    if [ ! -s "$f" ] || ! grep -q '^apiVersion:' "$f" 2>/dev/null; then
                      rm -f "$f"
                    fi
                  fi
                done

                ${prefixUtil.applyToDir { inherit prefix labNamespaces; } "$out/${sanitized}"}
                ${imageUtil.applyToDir {
                  lock = imageLock;
                  registry = imageRegistry;
                  exempt = imageExempt;
                  overrides = imageOverrides;
                } "$out/${sanitized}"}
              ''
          ) bundleEntries
        )}
      '';

  bootstrapPlaceholder = pkgs.writeText "${clusterName}-argocd-bootstrap-placeholder.yaml" ''
    ---
  '';

in
pkgs.runCommand "argocd-${clusterName}" { } ''
  mkdir -p "$out/${clusterName}/applications"
  mkdir -p "$out/${clusterName}/bundles"
  mkdir -p "$out/bootstrap/${clusterName}"

  cp -r ${applicationsDir}/* "$out/${clusterName}/applications/"
  if [ -d "${bundlesDir}" ] && [ -n "$(ls -A "${bundlesDir}" 2>/dev/null)" ]; then
    cp -r ${bundlesDir}/* "$out/${clusterName}/bundles/"
  fi

  cp ${rootApplicationFile} "$out/${clusterName}/root-app.yaml"

  cp ${bootstrapPlaceholder} "$out/bootstrap/${clusterName}/argocd-install.yaml"
  cp ${bootstrapPlaceholder} "$out/bootstrap/${clusterName}/argocd-values.yaml"

  echo "argocd" > "$out/${clusterName}/.deploy-strategy"
''
